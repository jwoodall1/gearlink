import Link from "next/link";
import { SignOut } from "@/components/sign-out";

const links = [
  ["/dashboard", "Overview", "◫"],
  ["/dashboard/equipment", "Equipment", "▧"],
  ["/dashboard/athletes", "Athletes", "♙"],
  ["/dashboard/activity", "Activity", "↗"],
] as const;

export function DashboardShell({ children, email, organization }: { children: React.ReactNode; email: string; organization: string | null }) {
  return <div className="app-shell"><aside className="sidebar">
    <Link className="wordmark" href="/dashboard"><span className="brand-mark small">G</span><span>gearlink<small>TEAM EQUIPMENT</small></span></Link>
    <div className="side-label">WORKSPACE</div><div className="org-switch"><span className="org-icon">{organization?.slice(0, 1) ?? "＋"}</span><span>{organization ?? "No organization"}<small>{organization ? "Organization" : "Setup required"}</small></span><span className="chevron">⌄</span></div>
    <div className="side-label nav-label">MANAGE</div><nav>{links.map(([href, label, icon], index) => <Link key={href} href={href} className={`nav-link ${index === 0 ? "active" : ""}`}><span>{icon}</span>{label}{label === "Activity" && <i className="nav-dot" />}</Link>)}</nav>
    <div className="sidebar-bottom"><div className="help-card"><span className="help-icon">✳</span><strong>Need a hand?</strong><p>Learn how to set up your team's gear.</p><a href="mailto:support@gearlink.app">Visit help center <span>↗</span></a></div><div className="user-row"><span className="avatar">{email.slice(0, 1).toUpperCase()}</span><span className="user-email">{email}<small>Administrator</small></span><SignOut /></div></div>
  </aside><main className="main-area">{children}</main></div>;
}
