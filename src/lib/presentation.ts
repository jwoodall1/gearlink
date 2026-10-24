export function relatedRow<T>(value: unknown): T | null {
  const row = Array.isArray(value) ? value[0] : value;
  return row && typeof row === "object" ? row as T : null;
}
export function equipmentName(value: unknown) {
  return relatedRow<{ name?: string }>(value)?.name || "Equipment record";
}
export function athleteName(value: unknown) {
  const row = relatedRow<{ first_name?: string; last_name?: string }>(value);
  return row ? `${row.first_name ?? ""} ${row.last_name ?? ""}`.trim() || "Athlete" : "No athlete linked";
}
export const eventLabels: Record<string, string> = {
  registered: "Registered", tagged: "NFC tag linked", checkout: "Issued",
  return: "Returned", updated: "Equipment updated", tag_disabled: "Tag disabled",
};
export function displayLabel(value: string) { return value.replaceAll("_", " "); }
export function pageNumber(value?: string) {
  const page = Number(value);
  return Number.isSafeInteger(page) && page > 0 ? Math.min(page, 100000) : 1;
}
export function dateLabel(value: string) {
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }).format(new Date(value));
}
