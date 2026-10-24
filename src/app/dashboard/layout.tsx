import { DashboardShell } from "@/components/dashboard-shell";
import { getWorkspace } from "@/lib/workspace";

export default async function DashboardLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const { email, organization, role } = await getWorkspace();
  return <DashboardShell email={email} organization={organization?.name ?? null} role={role}>{children}</DashboardShell>;
}
