const CANONICAL_UTC_INSTANT =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

export function isCanonicalUtcInstant(
  value: unknown,
): value is string {
  if (
    typeof value !== "string" ||
    !CANONICAL_UTC_INSTANT.test(value)
  ) {
    return false;
  }
  const milliseconds = Date.parse(value);
  return (
    Number.isFinite(milliseconds) &&
    new Date(milliseconds).toISOString() === value
  );
}

export function canonicalUtcDay(value: string): string {
  if (!isCanonicalUtcInstant(value)) {
    throw new TypeError("Expected a canonical UTC instant.");
  }
  return value.slice(0, 10);
}
