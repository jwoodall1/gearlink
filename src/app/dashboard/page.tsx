import Link from "next/link";
import { createOrganization } from "@/app/login/actions";
import { getDashboardData } from "@/lib/dashboard";
import { athleteName, equipmentName, eventLabels, dateLabel } from "@/lib/presentation";
import { EmptyState, MetricCard, PageHeading, Panel, StatusBadge } from "@/components/ui/workspace-ui";
import { SubmitButton } from "@/components/ui/submit-button";

export default async function DashboardPage({ searchParams }: { searchParams: Promise<{ setup?: string }> }) {
  const { setup } = await searchParams;
  const data = await getDashboardData();
  return <div className="content">
    <PageHeading eyebrow="PROGRAM OVERVIEW" title={data.organization?.name ?? "Welcome to GearLink"} description="Your equipment, your athletes, and what needs attention." action={data.organization && <Link className="button button-primary" href="/dashboard/equipment">View inventory <span aria-hidden="true">↗</span></Link>} />
    {!data.organization && <section className="setup-banner"><div className="setup-copy"><h2>Create your organization</h2><p>Give your program a home. Then add athletes to start building your roster.</p><form action={createOrganization} className="setup-form"><label className="sr-only" htmlFor="organization">Organization name</label><input id="organization" name="organization" minLength={2} maxLength={120} placeholder="e.g. Northside Athletics" required /><SubmitButton pendingLabel="Creating…">Create organization</SubmitButton></form></div></section>}
    {setup === "complete" && <p className="notice success" role="status">Your organization is ready. Add your first athlete from the roster.</p>}
    {setup === "error" && <p className="notice error" role="alert">We couldn't create the organization. Please try again.</p>}
    {setup === "invalid" && <p className="notice error" role="alert">Enter an organization name between 2 and 120 characters.</p>}
    {data.organization && <>
      <div className="stat-grid">
        <MetricCard label="Total equipment" value={data.equipmentCount} detail="All registered items, including retired" href="/dashboard/equipment" />
        <MetricCard label="Currently issued" value={data.assignmentCount} detail="Open equipment assignments" href="/dashboard/athletes" />
        <MetricCard label="Available" value={data.availableCount} detail="Items marked available" href="/dashboard/equipment?status=available" />
        <MetricCard label="Active athletes" value={data.athleteCount} detail="View your program's roster" href="/dashboard/athletes" />
      </div>
      <nav className="quick-actions" aria-label="Quick actions"><Link className="button button-secondary" href="/dashboard/athletes">View athletes</Link><Link className="button button-secondary" href="/dashboard/equipment">Browse inventory</Link><Link className="button button-secondary" href="/dashboard/activity">Review activity</Link></nav>
      <Panel title="Needs attention" description="Equipment marked for maintenance or repair. Retired items are excluded." action={<Link href="/dashboard/equipment?attention=true">Review {data.attentionCount} items ↗</Link>}>
        {data.attention.length ? <ul className="attention-list">{data.attention.map(item => <li key={item.id}><Link href={`/dashboard/equipment?item=${item.id}`}><strong>{item.name}</strong><StatusBadge value={item.condition === "needs_repair" ? item.condition : item.status} /></Link></li>)}</ul> : <EmptyState title="No maintenance or repair flags" description="Equipment needing attention will appear here when its condition or status is updated." />}
      </Panel>
      <div className="dashboard-grid">
        <Panel title="Current assignments" description="Eight most recent open assignments" action={<Link href="/dashboard/athletes">View roster ↗</Link>}>
          {data.assignments.length ? <div className="table-wrap" tabIndex={0} role="region" aria-label="Current assignments"><table><thead><tr><th scope="col">Equipment</th><th scope="col">Athlete</th><th scope="col">Issued</th></tr></thead><tbody>{data.assignments.map(item => <tr key={item.id}><td><strong>{equipmentName(item.equipment)}</strong></td><td>{athleteName(item.athletes)}</td><td>{dateLabel(item.checked_out_at)}</td></tr>)}</tbody></table></div> : <EmptyState title="No active assignments" description="Issued equipment will appear here once assignments are recorded." />}
        </Panel>
        <Panel title="Recent activity" description="Latest equipment updates" action={<Link href="/dashboard/activity">See all ↗</Link>}>
          {data.events.length ? <ul className="activity-list">{data.events.map(event => <li key={event.id}><span className="activity-mark" aria-hidden="true">{event.event_type === "return" ? "↙" : "↗"}</span><div><strong>{eventLabels[event.event_type] ?? event.event_type} · {equipmentName(event.equipment)}</strong><p>{athleteName(event.athletes)} · {dateLabel(event.created_at)}</p></div></li>)}</ul> : <EmptyState title="No activity yet" description="Equipment updates and assignment history will appear here." />}
        </Panel>
      </div>
      <p className="footnote">Showing {data.organization.name}. Refresh the page to see the latest changes from your team.</p>
    </>}
  </div>;
}
