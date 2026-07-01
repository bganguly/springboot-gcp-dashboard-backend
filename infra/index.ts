import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import * as random from "@pulumi/random";

const config    = new pulumi.Config();
const gcpConfig = new pulumi.Config("gcp");

const project       = gcpConfig.require("project");
const region        = gcpConfig.get("region")       ?? "us-central1";
const namePrefix    = config.get("namePrefix")       ?? "dash";
const dbName        = config.get("dbName")           ?? "app";
const dbUsername    = config.get("dbUsername")       ?? "appuser";
const dbTier        = config.get("dbTier")           ?? "db-custom-4-16384";
const dbDiskGb      = config.getNumber("dbDiskGb")   ?? 35;
const backendImage  = config.get("backendImage")     ?? "";
const frontendImage = config.get("frontendImage")    ?? "";

// ── APIs ──────────────────────────────────────────────────────────────────────
const apis = [
  "compute.googleapis.com",
  "sqladmin.googleapis.com",
  "run.googleapis.com",
  "artifactregistry.googleapis.com",
  "secretmanager.googleapis.com",
  "vpcaccess.googleapis.com",
  "servicenetworking.googleapis.com",
].map(api => new gcp.projects.Service(`api-${api.split(".")[0]}`, {
  project,
  service: api,
  disableOnDestroy: false,
}));

// ── VPC ───────────────────────────────────────────────────────────────────────
const network = new gcp.compute.Network("vpc", {
  name: `${namePrefix}-vpc`,
  autoCreateSubnetworks: false,
}, { dependsOn: apis });

const subnet = new gcp.compute.Subnetwork("subnet", {
  name: `${namePrefix}-subnet`,
  ipCidrRange: "10.8.0.0/20",
  region,
  network: network.id,
});

const connectorSubnet = new gcp.compute.Subnetwork("connector-subnet", {
  name: `${namePrefix}-connector-subnet`,
  ipCidrRange: "10.8.16.0/28",
  region,
  network: network.id,
});

const privateIpRange = new gcp.compute.GlobalAddress("sql-ip-range", {
  name: `${namePrefix}-sql-ip-range`,
  purpose: "VPC_PEERING",
  addressType: "INTERNAL",
  prefixLength: 20,
  network: network.id,
});

const privateVpc = new gcp.servicenetworking.Connection("private-vpc", {
  network: network.id,
  service: "servicenetworking.googleapis.com",
  reservedPeeringRanges: [privateIpRange.name],
}, { dependsOn: apis });

new gcp.compute.Firewall("allow-connector-to-sql", {
  name: `${namePrefix}-allow-connector-sql`,
  network: network.id,
  direction: "INGRESS",
  sourceRanges: ["10.8.16.0/28"],
  allows: [{ protocol: "tcp", ports: ["5432"] }],
});

const connector = new gcp.vpcaccess.Connector("connector", {
  name: `${namePrefix}-connector`,
  region,
  subnet: { name: connectorSubnet.name },
  minInstances: 2,
  maxInstances: 3,
}, { dependsOn: apis });

// ── Cloud SQL ─────────────────────────────────────────────────────────────────
const dbPassword = new random.RandomPassword("db-password", {
  length: 24,
  special: false,
});

const dbInstance = new gcp.sql.DatabaseInstance("pg", {
  name: `${namePrefix}-db`,
  databaseVersion: "POSTGRES_16",
  region,
  settings: {
    tier: dbTier,
    diskSize: dbDiskGb,
    diskAutoresize: true,
    ipConfiguration: {
      ipv4Enabled: false,
      privateNetwork: network.id,
      // Required for Cloud Run Direct VPC Egress to reach Cloud SQL private IP
      enablePrivatePathForGoogleCloudServices: true,
    },
    databaseFlags: [{ name: "max_connections", value: "200" }],
    backupConfiguration: { enabled: true },
  },
  deletionProtection: false,
}, { dependsOn: [privateVpc] });

new gcp.sql.Database("app-db", {
  name: dbName,
  instance: dbInstance.name,
});

new gcp.sql.User("app-user", {
  name: dbUsername,
  instance: dbInstance.name,
  password: dbPassword.result,
});

// ── Secret Manager ────────────────────────────────────────────────────────────
const dbUrlSecret = new gcp.secretmanager.Secret("database-url", {
  secretId: `${namePrefix}-database-url`,
  replication: { auto: {} },
}, { dependsOn: apis });

new gcp.secretmanager.SecretVersion("database-url-v1", {
  secret: dbUrlSecret.id,
  secretData: pulumi.interpolate`postgresql://${dbUsername}:${dbPassword.result}@${dbInstance.privateIpAddress}:5432/${dbName}`,
});

// ── Artifact Registry ─────────────────────────────────────────────────────────
const registry = new gcp.artifactregistry.Repository("repo", {
  location: region,
  repositoryId: `${namePrefix}-repo`,
  format: "DOCKER",
}, { dependsOn: apis });

// ── Service Account ───────────────────────────────────────────────────────────
const backendSa = new gcp.serviceaccount.Account("backend-sa", {
  accountId: `${namePrefix}-backend-sa`,
  displayName: "Dashboard Backend SA",
});

new gcp.secretmanager.SecretIamMember("backend-db-url-access", {
  secretId: dbUrlSecret.id,
  role: "roles/secretmanager.secretAccessor",
  member: pulumi.interpolate`serviceAccount:${backendSa.email}`,
});

new gcp.projects.IAMMember("backend-sql-access", {
  project,
  role: "roles/cloudsql.client",
  member: pulumi.interpolate`serviceAccount:${backendSa.email}`,
});

// ── Cloud Run: Backend ────────────────────────────────────────────────────────
const backendService = new gcp.cloudrunv2.Service("backend", {
  name: `${namePrefix}-backend`,
  location: region,
  template: {
    serviceAccount: backendSa.email,
    vpcAccess: {
      networkInterfaces: [{
        network: network.id,
        subnetwork: subnet.id,
      }],
      egress: "PRIVATE_RANGES_ONLY",
    },
    containers: [{
      image: backendImage !== "" ? backendImage : "us-docker.pkg.dev/cloudrun/container/hello",
      ports: [{ containerPort: 8080 }],
      resources: { limits: { cpu: "2", memory: "1Gi" } },
      startupProbe: {
        httpGet: { path: "/actuator/health" },
        initialDelaySeconds: 10,
        periodSeconds: 15,
        failureThreshold: 60,  // 60 * 15s = 15 min — covers long Flyway migrations
        timeoutSeconds: 5,
      },
      envs: [{
        name: "DATABASE_URL",
        valueSource: {
          secretKeyRef: {
            secret: dbUrlSecret.secretId,
            version: "latest",
          },
        },
      }],
    }],
    scaling: { minInstanceCount: 1, maxInstanceCount: 5 },
  },
  traffics: [{ type: "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", percent: 100 }],
}, { dependsOn: [registry] });

new gcp.cloudrunv2.ServiceIamMember("backend-public", {
  project,
  location: region,
  name: backendService.name,
  role: "roles/run.invoker",
  member: "allUsers",
});

// ── Cloud Run: Frontend ───────────────────────────────────────────────────────
const frontendService = new gcp.cloudrunv2.Service("frontend", {
  name: `${namePrefix}-frontend`,
  location: region,
  template: {
    containers: [{
      image: frontendImage !== "" ? frontendImage : "us-docker.pkg.dev/cloudrun/container/hello",
      ports: [{ containerPort: 80 }],
      resources: { limits: { cpu: "1", memory: "512Mi" } },
      envs: [{
        name: "BACKEND_URL",
        value: backendService.uri,
      }],
    }],
    scaling: { minInstanceCount: 0, maxInstanceCount: 3 },
  },
  traffics: [{ type: "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", percent: 100 }],
}, { dependsOn: [backendService] });

new gcp.cloudrunv2.ServiceIamMember("frontend-public", {
  project,
  location: region,
  name: frontendService.name,
  role: "roles/run.invoker",
  member: "allUsers",
});

// ── Outputs ───────────────────────────────────────────────────────────────────
export const cloudSqlInstance  = dbInstance.connectionName;
export const artifactRegistry  = pulumi.interpolate`${region}-docker.pkg.dev/${project}/${registry.repositoryId}`;
export const backendUrl        = backendService.uri;
export const frontendUrl       = frontendService.uri;
export const databaseUrl       = pulumi.secret(
  pulumi.interpolate`postgresql://${dbUsername}:${dbPassword.result}@${dbInstance.privateIpAddress}:5432/${dbName}`
);
