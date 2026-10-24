export default function DashboardLoading() {
  return <div className="content" role="status" aria-live="polite" aria-busy="true"><p className="eyebrow">GEARLINK</p><h1>Loading your workspace…</h1><div className="stat-grid skeleton-grid" aria-hidden="true">{[1, 2, 3, 4].map(key => <div key={key} className="stat-card skeleton" />)}</div><div className="panel skeleton skeleton-panel" aria-hidden="true" /></div>;
}
