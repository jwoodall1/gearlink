import { createClient } from "@/lib/supabase/server";

const labels: Record<string, string> = { registered: "Registered", tagged: "NFC tag linked", checkout: "Checked out", return: "Returned", updated: "Equipment updated", tag_disabled: "Tag disabled" };
export default async function ActivityPage() {
  const supabase = await createClient();
  const { data: rows, error } = await supabase.from("equipment_events").select("id, event_type, created_at, equipment(name), athletes(first_name, last_name)").order("created_at", { ascending: false }).limit(100);
  return <div className="content"><div className="page-heading"><div><p className="eyebrow">AUDIT LOG</p><h1>Activity</h1><p className="muted">A record of equipment updates and assignments.</p></div></div>
    <section className="panel list-panel"><div className="panel-heading"><div><h2>Recent events</h2><p>Most recent first · up to 100 events</p></div><span className="count-badge">{rows?.length ?? 0} events</span></div>
      {error ? <div className="inline-error">Unable to load activity. Check your database migration and access permissions.</div> : rows?.length ? <ul className="activity-list full-activity">{rows.map((event) => <li key={event.id}><span className="activity-mark">{event.event_type === "checkout" ? "↗" : event.event_type === "return" ? "↙" : "＋"}</span><div><strong>{labels[event.event_type] ?? event.event_type} · {relationName(event.equipment)}</strong><p>{personName(event.athletes)} <span>· {new Date(event.created_at).toLocaleString()}</span></p></div></li>)}</ul> : <div className="empty-state"><span className="empty-icon">◷</span><strong>No activity yet</strong><p>Equipment registrations, checkouts, and returns will appear here.</p></div>}
    </section></div>;
}

function relationName(value: unknown) { const row = Array.isArray(value) ? value[0] : value; return row && typeof row === "object" && "name" in row ? String((row as { name: unknown }).name) : "Equipment"; }
function personName(value: unknown) { const row = Array.isArray(value) ? value[0] : value; if (!row || typeof row !== "object") return "Equipment record"; const person = row as Record<string, unknown>; return `${person.first_name ?? ""} ${person.last_name ?? ""}`.trim() || "Equipment record"; }
