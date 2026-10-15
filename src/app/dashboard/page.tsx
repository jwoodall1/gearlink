import Link from "next/link";
import { createOrganization } from "@/app/login/actions";
import { getDashboardData } from "@/lib/dashboard";

const dateLabel = new Intl.DateTimeFormat("en-US", { weekday: "long", month: "long", day: "numeric" }).format(new Date());

export default async function DashboardPage({ searchParams }: { searchParams: Promise<{ setup?: string }> }) {
  const { setup } = await searchParams;
  let data;
  try { data = await getDashboardData(); } catch {
    return <div className="content"><p className="eyebrow">OVERVIEW</p><h1>We couldn't load your workspace</h1><p className="muted">Check your Supabase connection and migration, then reload.</p><Link className="button button-primary" href="/dashboard">Try again</Link></div>;
  }

  const activeCount = data.assignmentCount;
  const availableCount = data.equipment.filter((item) => item.status === "available").length;
  return <div className="content">
    <div className="page-heading"><div><p className="eyebrow">{dateLabel.toUpperCase()}</p><h1>Good gear. Great game.</h1><p className="muted">Here's what's happening with your equipment.</p></div><Link className="button button-primary" href="/dashboard/equipment">＋ <span>Add equipment</span></Link></div>
    {!data.organization && <section className="setup-banner"><span className="setup-symbol">↗</span><div className="setup-copy"><strong>Your workspace is ready for its first organization</strong><p>Create an organization to start managing equipment and athlete records. You'll be its first administrator.</p><form action={createOrganization} className="setup-form"><label className="sr-only" htmlFor="organization">Organization name</label><input id="organization" name="organization" minLength={2} maxLength={120} placeholder="e.g. Northside Athletics" required /><button className="button button-primary" type="submit">Create organization</button></form></div></section>}
    {setup === "complete" && <p className="notice success" role="status">Your organization is ready.</p>}
    {setup === "error" && <p className="notice error" role="alert">We couldn't create the organization. Please check the name and try again.</p>}
    {setup === "invalid" && <p className="notice error" role="alert">Enter an organization name between 2 and 120 characters.</p>}
    <div className="stat-grid">
      <article className="stat-card"><div className="stat-top"><span>Total equipment</span><i className="stat-icon blue">▧</i></div><strong>{data.equipmentCount}</strong><small>Registered in your organization</small><div className="stat-foot"><span className="mini-bars"><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/></span><span>All gear</span></div></article>
      <article className="stat-card"><div className="stat-top"><span>Checked out</span><i className="stat-icon orange">↗</i></div><strong>{activeCount}</strong><small>Items with athletes</small><div className="stat-foot"><span className="stat-positive">● Live</span><span>Current assignments</span></div></article>
      <article className="stat-card"><div className="stat-top"><span>Available</span><i className="stat-icon green">✓</i></div><strong>{availableCount}</strong><small>Ready to be assigned</small><div className="stat-foot"><span className="stat-positive">● Ready</span><span>In inventory</span></div></article>
      <article className="stat-card"><div className="stat-top"><span>Athletes</span><i className="stat-icon violet">♙</i></div><strong>{data.athletes.length}</strong><small>Active roster</small><div className="stat-foot"><Link href="/dashboard/athletes">View roster <span>↗</span></Link><span>Organization members</span></div></article>
    </div>
    <div className="dashboard-grid"><section className="panel assignments-panel"><div className="panel-heading"><div><h2>Current assignments</h2><p>Equipment checked out to athletes</p></div><Link href="/dashboard/activity">View activity <span>↗</span></Link></div>
      {data.assignments.length ? <div className="table-wrap"><table><thead><tr><th>Equipment</th><th>Athlete</th><th>Checked out</th><th>Status</th></tr></thead><tbody>{data.assignments.map((item) => <tr key={item.id}><td>{relationName(item.equipment, "name")}</td><td>{personName(item.athletes)}</td><td>{new Date(item.checked_out_at).toLocaleDateString()}</td><td><span className="pill checked">Checked out</span></td></tr>)}</tbody></table></div> : <div className="empty-state"><span className="empty-icon">↗</span><strong>No active checkouts</strong><p>{data.organization ? "Items checked out to athletes will show up here." : "Your equipment and assignments will show up here once setup is complete."}</p></div>}
    </section><section className="panel activity-panel"><div className="panel-heading"><div><h2>Recent activity</h2><p>Latest equipment updates</p></div><Link href="/dashboard/activity">See all <span>↗</span></Link></div>
      {data.events.length ? <ul className="activity-list">{data.events.map((event) => <li key={event.id}><span className="activity-mark">{event.event_type === "checkout" ? "↗" : event.event_type === "return" ? "↙" : "＋"}</span><div><strong>{event.event_type === "checkout" ? "Checked out" : event.event_type === "return" ? "Returned" : "Equipment updated"} · {relationName(event.equipment, "name")}</strong><p>{personName(event.athletes)} <span>· {new Date(event.created_at).toLocaleDateString()}</span></p></div></li>)}</ul> : <div className="empty-state compact"><span className="empty-icon">◷</span><strong>Nothing to report yet</strong><p>Equipment activity will appear here.</p></div>}
    </section></div>
    <div className="footnote"><span className="footnote-dot"/>Your data is private to {data.organization?.name ?? "your organization"}. <Link href="/dashboard/equipment">Manage inventory <span>↗</span></Link></div>
  </div>;
}

function relationName(value: unknown, key: string) {
  const row = Array.isArray(value) ? value[0] : value;
  return row && typeof row === "object" && key in row ? String((row as Record<string, unknown>)[key]) : "Equipment";
}
function personName(value: unknown) {
  const row = Array.isArray(value) ? value[0] : value;
  if (!row || typeof row !== "object") return "Athlete";
  const person = row as Record<string, unknown>;
  return `${person.first_name ?? ""} ${person.last_name ?? ""}`.trim() || "Athlete";
}
