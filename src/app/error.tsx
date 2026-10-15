"use client";

export default function ErrorPage({ reset }: { reset: () => void }) {
  return <div className="content"><h1>We couldn't load this page</h1><p className="muted" role="alert">Please try again in a moment.</p><button className="button button-primary" onClick={reset}>Try again</button></div>;
}
