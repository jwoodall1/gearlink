import type { Metadata } from "next";
import "./styles.css";

export const metadata: Metadata = {
  title: "GearLink | Equipment management",
  description: "Manage your organization's athletic equipment and assignments.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
