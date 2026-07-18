// AmisAd web SPA shell - POC skeleton.
// One shell, seven role-scoped modules (per plan/design.md): seller, resource,
// ads, insights, platform, audit, connect. Each module is an empty placeholder
// until its scenarios land.

import { BrowserRouter, Link, Route, Routes } from "react-router-dom";
import RoleModule from "./modules/RoleModule";

const MODULES = [
  { path: "seller", title: "Seller" },
  { path: "resource", title: "Resource" },
  { path: "ads", title: "Ads" },
  { path: "insights", title: "Insights" },
  { path: "platform", title: "Platform" },
  { path: "audit", title: "Audit" },
  { path: "connect", title: "Connect" },
];

function Home() {
  return (
    <div className="amisad-home">
      <img src="/icon.svg" alt="AmisAd" width={64} height={64} />
      <h1>AmisAd</h1>
      <p>POC skeleton - pick a workspace.</p>
      <nav>
        {MODULES.map((m) => (
          <Link key={m.path} to={`/${m.path}`}>
            {m.title}
          </Link>
        ))}
      </nav>
    </div>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Home />} />
        {MODULES.map((m) => (
          <Route
            key={m.path}
            path={`/${m.path}`}
            element={<RoleModule title={m.title} />}
          />
        ))}
      </Routes>
    </BrowserRouter>
  );
}
