import { Routes, Route } from "react-router-dom";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import Members from "./pages/Members";
import Governance from "./pages/Governance";
import Orders from "./pages/Orders";
import Treasury from "./pages/Treasury";
import MyProfile from "./pages/MyProfile";

export default function App() {
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/members" element={<Members />} />
        <Route path="/governance" element={<Governance />} />
        <Route path="/orders" element={<Orders />} />
        <Route path="/treasury" element={<Treasury />} />
        <Route path="/profile" element={<MyProfile />} />
      </Routes>
    </Layout>
  );
}
