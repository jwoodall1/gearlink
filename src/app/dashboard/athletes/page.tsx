import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { createAthlete } from "./actions";

export default async function AthletesPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const { status } = await searchParams;
  const supabase = await createClient();
  const { data: rows, error } = await supabase.from("athletes").select("id, first_name, last_name, team, active, equipment_assignments(id, equipment(name), checked_out_at, returned_at)").eq("active", true).order("last_name");
  return <div className="content"><div className="page-heading"><div><p className="eyebrow">ROSTER</p><h1>Athletes</h1><p className="muted">See your active roster and assigned gear.</p></div></div>
    {status === "created" && <p className="notice success" role="status">Athlete added to your roster.</p>}
    {status === "invalid" && <p className="notice error" role="alert">Enter a first name and last name. Each name must be 80 characters or fewer.</p>}
    {status === "workspace" && <p className="notice error" role="alert">Create an organization before adding athletes.</p>}
    {status === "error" && <p className="notice error" role="alert">We couldn't add that athlete. Confirm that you have administrator access and try again.</p>}
    <section className="panel roster-create-panel"><div className="panel-heading"><div><h2>Add an athlete</h2><p>Rostered athletes can be assigned equipment later.</p></div></div>
      <form action={createAthlete} className="athlete-form">
        <label>First name<input name="first_name" autoComplete="given-name" maxLength={80} required /></label>
        <label>Last name<input name="last_name" autoComplete="family-name" maxLength={80} required /></label>
        <label>Team <span className="label-optional">(optional)</span><input name="team" autoComplete="organization" maxLength={120} /></label>
        <button className="button button-primary" type="submit">Add to roster</button>
      </form>
    </section>
    <section className="panel list-panel"><div className="panel-heading"><div><h2>Active athletes</h2><p>Only athletes from your organization are shown</p></div><span className="count-badge">{rows?.length ?? 0} athletes</span></div>
      {error ? <div className="inline-error">Unable to load the roster. Check your database migration and access permissions.</div> : rows?.length ? <div className="table-wrap"><table><thead><tr><th>Athlete</th><th>Team</th><th>Equipment checked out</th></tr></thead><tbody>{rows.map((athlete) => <tr key={athlete.id}><td><span className="person-cell"><span className="person-avatar">{athlete.first_name[0]}{athlete.last_name[0]}</span><strong>{athlete.first_name} {athlete.last_name}</strong></span></td><td>{athlete.team ?? "—"}</td><td>{athlete.equipment_assignments?.filter((a) => !a.returned_at).map((a) => a.equipment?.[0]?.name).filter(Boolean).join(", ") || "No active assignments"}</td></tr>)}</tbody></table></div> : <div className="empty-state"><span className="empty-icon">♙</span><strong>No athletes on the roster</strong><p>Ask an organization administrator to add athletes to the roster.</p><Link className="text-link" href="/dashboard">Back to overview <span>↗</span></Link></div>}
    </section></div>;
}
