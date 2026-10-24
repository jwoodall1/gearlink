import Link from "next/link";
import Image from "next/image";
import { DashboardNav } from "@/components/dashboard-nav";
import { SignOut } from "@/components/sign-out";

export function DashboardShell({ children, email, organization, role }: { children: React.ReactNode; email: string; organization: string | null; role?: "admin" | "coach" }) {
  return <div className="app-shell"><a className="skip-link" href="#main-content">Skip to content</a><aside className="sidebar">
    <Link className="wordmark" href="/dashboard" aria-label="GearLink overview"><Image src="/brand/gearlink-logo.png" alt="GearLink" width={2172} height={724} sizes="220px" priority /><small>TEAM EQUIPMENT MANAGEMENT</small></Link>
    <div className="side-label">WORKSPACE</div><div className="org-switch"><span className="org-icon" aria-hidden="true">{organization?.slice(0, 1) ?? "＋"}</span><span>{organization ?? "No organization"}<small>{organization ? "Current organization" : "Setup required"}</small></span></div>
    <div className="side-label nav-label">MANAGE</div><DashboardNav />
    <div className="sidebar-bottom"><div className="user-row"><span className="avatar" aria-hidden="true">{email.slice(0, 1).toUpperCase()}</span><span className="user-email" title={email}>{email}<small>{role === "admin" ? "Administrator" : role === "coach" ? "Coach" : "Account"}</small></span></div><SignOut /></div>
  </aside><main id="main-content" className="main-area" tabIndex={-1}>{children}</main></div>;
}
