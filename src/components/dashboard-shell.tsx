import Link from "next/link";
import Image from "next/image";
import { DashboardNav } from "@/components/dashboard-nav";
import { SignOut } from "@/components/sign-out";

export function DashboardShell({ children, email, organization }: { children: React.ReactNode; email: string; organization: string | null }) {
  return <div className="app-shell"><aside className="sidebar">
    <Link className="wordmark" href="/dashboard" aria-label="GearLink overview"><Image src="/brand/gearlink-logo.png" alt="GearLink" width={2172} height={724} sizes="220px" priority /><small>TEAM EQUIPMENT MANAGEMENT</small></Link>
    <div className="side-label">WORKSPACE</div><div className="org-switch"><span className="org-icon">{organization?.slice(0, 1) ?? "＋"}</span><span>{organization ?? "No organization"}<small>{organization ? "Organization" : "Setup required"}</small></span><span className="chevron">⌄</span></div>
    <div className="side-label nav-label">MANAGE</div><DashboardNav />
    <div className="sidebar-bottom"><div className="help-card"><span className="help-icon">✳</span><strong>Need a hand?</strong><p>Learn how to set up your team's gear.</p><a href="mailto:support@gearlink.app">Visit help center <span>↗</span></a></div><div className="user-row"><span className="avatar">{email.slice(0, 1).toUpperCase()}</span><span className="user-email">{email}<small>Administrator</small></span><SignOut /></div></div>
  </aside><main className="main-area">{children}</main></div>;
}
