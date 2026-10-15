import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function AthletesPage() {
  const supabase = await createClient();
  const { data: rows, error } = await supabase.from("athletes").select("id, first_name, last_name, team, active, equipment_assignments(id, equipment(name), checked_out_at, returned_at)").eq("active", true).order("last_name");
  return <div className="content"><div className="page-heading"><div><p className="eyebrow">ROSTER</p><h1>Athletes</h1><p className="muted">See your active roster and assigned gear.</p></div><button className="button button-primary" disabled>＋ <span>Add athlete</span></button></div>
    <section className="panel list-panel"><div className="panel-heading"><div><h2>Active athletes</h2><p>Only athletes from your organization are shown</p></div><span className="count-badge">{rows?.length ?? 0} athletes</span></div>
      {error ? <div className="inline-error">Unable to load the roster. Check your database migration and access permissions.</div> : rows?.length ? <div className="table-wrap"><table><thead><tr><th>Athlete</th><th>Team</th><th>Equipment checked out</th></tr></thead><tbody>{rows.map((athlete) => <tr key={athlete.id}><td><span className="person-cell"><span className="person-avatar">{athlete.first_name[0]}{athlete.last_name[0]}</span><strong>{athlete.first_name} {athlete.last_name}</strong></span></td><td>{athlete.team ?? "—"}</td><td>{athlete.equipment_assignments?.filter((a) => !a.returned_at).map((a) => a.equipment?.[0]?.name).filter(Boolean).join(", ") || "No active assignments"}</td></tr>)}</tbody></table></div> : <div className="empty-state"><span className="empty-icon">♙</span><strong>No athletes on the roster</strong><p>Ask an organization administrator to add athletes to the roster.</p><Link className="text-link" href="/dashboard">Back to overview <span>↗</span></Link></div>}
    </section></div>;
}
