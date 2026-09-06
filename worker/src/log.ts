/**
 * Structured logging. One JSON object per line, because these end up in Fly's
 * log stream and a human reading them there is the exception, not the rule.
 */

type Fields = Record<string, unknown>;

function emit(level: "info" | "warn" | "error", message: string, fields: Fields): void {
  const line = JSON.stringify({
    at: new Date().toISOString(),
    level,
    message,
    ...fields,
  });
  if (level === "error") {
    process.stderr.write(`${line}\n`);
  } else {
    process.stdout.write(`${line}\n`);
  }
}

export const log = {
  info: (message: string, fields: Fields = {}) => emit("info", message, fields),
  warn: (message: string, fields: Fields = {}) => emit("warn", message, fields),
  /** Errors are unwrapped here so a stack never reaches the log as "[object Object]". */
  error: (message: string, error: unknown, fields: Fields = {}) =>
    emit("error", message, {
      ...fields,
      error: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack : undefined,
    }),
};
