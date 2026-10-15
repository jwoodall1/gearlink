"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const links = [
  ["/dashboard", "Overview", "◫"],
  ["/dashboard/equipment", "Equipment", "▧"],
  ["/dashboard/athletes", "Athletes", "♙"],
  ["/dashboard/activity", "Activity", "↗"],
] as const;

export function DashboardNav() {
  const pathname = usePathname();
  return <nav aria-label="Main navigation">{links.map(([href, label, icon]) => {
    const active = href === "/dashboard" ? pathname === href : pathname.startsWith(href);
    return <Link key={href} href={href} className={`nav-link${active ? " active" : ""}`} aria-current={active ? "page" : undefined}><span aria-hidden="true">{icon}</span>{label}</Link>;
  })}</nav>;
}
