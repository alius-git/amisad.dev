// Placeholder for a role-scoped module. Real workspaces (catalog, control
// plane, campaigns, ...) replace this per module as scenarios land.

import { Link } from "react-router-dom";

export default function RoleModule({ title }: { title: string }) {
  return (
    <div className="amisad-module">
      <header>
        <Link to="/">AmisAd</Link>
        <h1>{title}</h1>
      </header>
      <p>POC skeleton - the {title.toLowerCase()} workspace lands with its scenarios.</p>
    </div>
  );
}
