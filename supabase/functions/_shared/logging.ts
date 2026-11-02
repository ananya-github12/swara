/** Structured, metadata-only logging for Swara Edge Functions. */

import { boundedTrimmedString, numberValue, strictObject, ValidationError } from "./validation.ts";

export const LOG_METADATA_KEYS = [
  "function",
  "event",
  "correlation",
  "status",
  "duration",
  "attempt",
  "queue",
  "message_id",
] as const;

export type LogMetadataKey = (typeof LOG_METADATA_KEYS)[number];
export type LogMetadata = Partial<
  Record<Extract<LogMetadataKey, "function" | "event" | "correlation" | "status" | "queue" | "message_id">, string>
> & Partial<Record<Extract<LogMetadataKey, "duration" | "attempt">, number>>;

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface StructuredLogRecord extends LogMetadata {
  readonly level: LogLevel;
  readonly timestamp: string;
}

const FORBIDDEN_LOG_FIELD = /(?:token|key|password|cookie|body|payload|content|value)/i;
const MAX_LOG_STRING_LENGTH = 256;

function rejectSensitiveFields(value: unknown, seen = new Set<object>()): void {
  if (value === null || typeof value !== "object") return;
  if (seen.has(value)) throw new ValidationError("Log metadata must not contain cycles");
  seen.add(value);
  if (Array.isArray(value)) {
    for (const item of value) rejectSensitiveFields(item, seen);
  } else {
    for (const [key, child] of Object.entries(value)) {
      if (FORBIDDEN_LOG_FIELD.test(key)) {
        throw new ValidationError("Log metadata contains a forbidden field", key);
      }
      rejectSensitiveFields(child, seen);
    }
  }
  seen.delete(value);
}

function logString(value: unknown, field: string): string {
  return boundedTrimmedString(value, {
    minLength: 1,
    maxLength: MAX_LOG_STRING_LENGTH,
    normalize: false,
    label: field,
  });
}

/** Validate and copy only the allowlisted, scalar, non-secret log metadata. */
export function sanitizeLogMetadata(value: unknown): LogMetadata {
  rejectSensitiveFields(value);
  const input = strictObject(value, LOG_METADATA_KEYS, { label: "log metadata" });
  const output: Record<string, string | number> = {};
  for (const key of LOG_METADATA_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(input, key)) continue;
    const fieldValue = input[key];
    if (key === "duration") {
      output[key] = numberValue(fieldValue, { min: 0, max: 86_400_000, label: key });
    } else if (key === "attempt") {
      output[key] = numberValue(fieldValue, { min: 0, max: 1_000_000, integer: true, label: key });
    } else {
      output[key] = logString(fieldValue, key);
    }
  }
  return Object.freeze(output) as LogMetadata;
}

export type LogSink = (line: string) => void;

const defaultSink: LogSink = (line) => console.log(line);

/** Emit one JSON log line. Input metadata is copied and never raw-serialized. */
export function structuredLog(
  level: LogLevel,
  metadata: unknown,
  sink: LogSink = defaultSink,
): StructuredLogRecord {
  if (!["debug", "info", "warn", "error"].includes(level)) {
    throw new ValidationError("Invalid log level", "level");
  }
  const safeMetadata = sanitizeLogMetadata(metadata);
  const record = Object.freeze({
    level,
    timestamp: new Date().toISOString(),
    ...safeMetadata,
  }) as StructuredLogRecord;
  sink(JSON.stringify(record));
  return record;
}

export function createStructuredLogger(sink: LogSink = defaultSink) {
  return Object.freeze({
    debug: (metadata: unknown) => structuredLog("debug", metadata, sink),
    info: (metadata: unknown) => structuredLog("info", metadata, sink),
    warn: (metadata: unknown) => structuredLog("warn", metadata, sink),
    error: (metadata: unknown) => structuredLog("error", metadata, sink),
  });
}

export const log = structuredLog;
