/**
 * Narrow direct-Postgres boundary for Swara Edge Functions.
 *
 * Private schemas and pgmq are deliberately unavailable through the Data API.
 * Edge Functions that need them connect with separately provisioned login roles
 * which inherit only `swara_api_runtime` or `swara_worker_runtime` privileges.
 * The platform-provided `SUPABASE_DB_URL` is intentionally never consulted.
 */

export type RuntimeDatabaseKind = "api" | "worker";

export type SqlRow = Readonly<Record<string, unknown>>;

/** Parameterized tagged-template query surface supplied by postgres.js. */
export interface SqlTransaction {
  <T extends SqlRow = SqlRow>(
    strings: TemplateStringsArray,
    ...values: readonly unknown[]
  ): Promise<readonly T[]>;
}

interface SqlClient {
  begin<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T>;
  end(options?: { readonly timeout?: number }): Promise<void>;
}

interface PostgresOptions {
  readonly application_name: string;
  readonly connect_timeout: number;
  readonly idle_timeout: number;
  readonly max: number;
  readonly max_lifetime: number;
  readonly prepare: false;
  readonly ssl: false | "require";
}

export type PostgresFactory = (url: string, options: PostgresOptions) => SqlClient;
export type EnvironmentReader = (name: string) => string | undefined;

const ENVIRONMENT_VARIABLES: Readonly<Record<RuntimeDatabaseKind, string>> = {
  api: "SWARA_API_DATABASE_URL",
  worker: "SWARA_WORKER_DATABASE_URL",
};

const FORBIDDEN_DATABASE_USERS = new Set([
  "anon",
  "authenticator",
  "postgres",
  "service_role",
  "supabase_admin",
  "swara_api_runtime",
  "swara_worker_runtime",
]);

export class RuntimeDatabaseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RuntimeDatabaseError";
  }
}

export class RuntimeDatabase {
  readonly kind: RuntimeDatabaseKind;
  readonly #client: SqlClient;
  #closed = false;

  private constructor(kind: RuntimeDatabaseKind, client: SqlClient) {
    this.kind = kind;
    this.#client = client;
  }

  static async fromEnvironment(
    kind: RuntimeDatabaseKind,
    options: {
      readonly environment?: EnvironmentReader;
      readonly factory?: PostgresFactory;
    } = {},
  ): Promise<RuntimeDatabase> {
    const environment = options.environment ?? defaultEnvironmentReader;
    const variable = ENVIRONMENT_VARIABLES[kind];
    const connectionUrl = validateRuntimeDatabaseUrl(environment(variable), variable);
    const parsed = new URL(connectionUrl);
    const factory = options.factory ?? await loadPostgresFactory();

    let client: SqlClient;
    try {
      client = factory(connectionUrl, {
        application_name: `swara-edge-${kind}`,
        connect_timeout: 10,
        idle_timeout: 20,
        max: 1,
        max_lifetime: 300,
        prepare: false,
        ssl: isLoopbackHost(parsed.hostname) ? false : "require",
      });
    } catch {
      throw new RuntimeDatabaseError("Runtime database could not be configured.");
    }
    return new RuntimeDatabase(kind, client);
  }

  /** Run all private-database work atomically on one transaction connection. */
  async transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T> {
    if (this.#closed) {
      throw new RuntimeDatabaseError("Runtime database is closed.");
    }
    try {
      return await this.#client.begin(callback);
    } catch (error) {
      if (error instanceof RuntimeDatabaseError) throw error;
      // Driver failures may contain credentials or query values. Do not retain
      // the original message or exception chain at this boundary.
      throw new RuntimeDatabaseError("Runtime database transaction failed.");
    }
  }

  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    try {
      await this.#client.end({ timeout: 5 });
    } catch {
      throw new RuntimeDatabaseError("Runtime database could not be closed.");
    }
  }
}

export function validateRuntimeDatabaseUrl(value: string | undefined, variable: string): string {
  if (!value?.trim()) {
    throw new RuntimeDatabaseError(`${variable} is required.`);
  }

  let parsed: URL;
  try {
    parsed = new URL(value.trim());
  } catch {
    throw new RuntimeDatabaseError(`${variable} must be a valid PostgreSQL URL.`);
  }

  if (parsed.protocol !== "postgres:" && parsed.protocol !== "postgresql:") {
    throw new RuntimeDatabaseError(`${variable} must use the PostgreSQL protocol.`);
  }
  if (!parsed.hostname || !parsed.username || !parsed.password || parsed.hash) {
    throw new RuntimeDatabaseError(`${variable} must include dedicated login credentials and a host.`);
  }

  let databaseUser: string;
  try {
    databaseUser = decodeURIComponent(parsed.username).toLowerCase();
  } catch {
    throw new RuntimeDatabaseError(`${variable} contains an invalid database user.`);
  }
  if (
    FORBIDDEN_DATABASE_USERS.has(databaseUser) ||
    databaseUser.startsWith("postgres.") ||
    databaseUser.startsWith("postgres_")
  ) {
    throw new RuntimeDatabaseError(`${variable} must use a dedicated Swara login role.`);
  }

  // A remote runtime connection must require TLS. postgres.js receives the
  // same requirement as a client option; checking the URL prevents an
  // accidentally misleading sslmode=disable setting from reaching production.
  const sslMode = parsed.searchParams.get("sslmode")?.toLowerCase();
  if (!isLoopbackHost(parsed.hostname) && sslMode !== null && sslMode !== "require" && sslMode !== "verify-full") {
    throw new RuntimeDatabaseError(`${variable} must not disable TLS.`);
  }
  return value.trim();
}

function isLoopbackHost(hostname: string): boolean {
  return hostname === "127.0.0.1" || hostname === "::1" || hostname === "localhost";
}

function defaultEnvironmentReader(name: string): string | undefined {
  return Deno.env.get(name);
}

async function loadPostgresFactory(): Promise<PostgresFactory> {
  try {
    const module = await import("postgres");
    if (typeof module.default !== "function") throw new TypeError("postgres default export is not callable");
    return module.default as PostgresFactory;
  } catch {
    throw new RuntimeDatabaseError("The runtime database driver is unavailable.");
  }
}
