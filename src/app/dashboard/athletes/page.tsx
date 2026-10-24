import { getWorkspace } from "@/lib/workspace";
import { equipmentName, pageNumber } from "@/lib/presentation";
import { EmptyState, PageHeading, Panel, Pagination, WorkspaceRequired } from "@/components/ui/workspace-ui";
import { SubmitButton } from "@/components/ui/submit-button";
import { createAthlete } from "./actions";

const pageSize = 50;
export default async function AthletesPage({ searchParams }: { searchParams: Promise<{ status?: string; page?: string }> }) {
  const { status, page: requestedPage } = await searchParams;
  const { supabase, organization, role } = await getWorkspace();
  if (!organization) return <div className="content"><PageHeading eyebrow="ROSTER" title="Athletes" description="Your active roster and assigned gear." /><WorkspaceRequired /></div>;
  const page = pageNumber(requestedPage);
  const { data: rows, count, error } = await supabase.from("athletes").select("id, first_name, last_name, team, active, equipment_assignments(id, equipment(name), returned_at)", { count: "exact" }).eq("organization_id", organization.id).eq("active", true).order("last_name").order("first_name").order("id").range((page - 1) * pageSize, page * pageSize - 1);
  if (error) throw error;
  return <div className="content"><PageHeading eyebrow="ROSTER" title="Athletes" description="See your active roster and each athlete's assigned gear." />
    {status === "created" && <p className="notice success" role="status">Athlete added to your roster.</p>}
    {status === "invalid" && <p className="notice error" role="alert">Enter both names (up to 80 characters each). Team can be up to 120 characters.</p>}
    {status === "error" && <p className="notice error" role="alert">We couldn't add that athlete. Check your connection and try again.</p>}
    {status === "forbidden" && <p className="notice error" role="alert">Only organization administrators can add athletes.</p>}
    {role === "admin" ? <section className="panel roster-create-panel"><div className="panel-heading"><div><h2>Add an athlete</h2><p>Build your active roster.</p></div></div><form action={createAthlete} className="athlete-form"><label>First name<input name="first_name" autoComplete="given-name" maxLength={80} required /></label><label>Last name<input name="last_name" autoComplete="family-name" maxLength={80} required /></label><label>Team (optional)<input name="team" maxLength={120} /></label><SubmitButton pendingLabel="Adding…">Add to roster</SubmitButton></form></section> : <p className="notice">You have roster viewing access. Ask an administrator to add or update athletes.</p>}
    <Panel title="Active athletes" description="Athletes in your current organization" action={<span className="count-badge">{count ?? 0} athletes</span>}>
      {rows?.length ? <div className="table-wrap" tabIndex={0} role="region" aria-label="Athlete roster"><table><thead><tr><th scope="col">Athlete</th><th scope="col">Team</th><th scope="col">Equipment issued</th></tr></thead><tbody>{rows.map(athlete => <tr key={athlete.id}><td><span className="person-cell"><span className="person-avatar" aria-hidden="true">{athlete.first_name[0]}{athlete.last_name[0]}</span><strong>{athlete.first_name} {athlete.last_name}</strong></span></td><td>{athlete.team || "No team"}</td><td>{athlete.equipment_assignments?.filter(a => !a.returned_at).map(a => equipmentName(a.equipment)).join(", ") || "No active assignments"}</td></tr>)}</tbody></table></div> : <EmptyState title={page > 1 ? "No athletes on this page" : "Your roster starts here"} description={role === "admin" ? "Use the form above to add an athlete, or return to the first page." : "Your administrator can add athletes to this program."} />}
      <Pagination page={page} count={count ?? 0} pageSize={pageSize} href="/dashboard/athletes" />
    </Panel></div>;
}
