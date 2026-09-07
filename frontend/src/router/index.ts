import { createRouter, createWebHashHistory } from "vue-router";

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", name: "dashboard", component: () => import("../views/DashboardView.vue"), meta: { title: "首页" } },
    { path: "/game", name: "game", component: () => import("../views/LiveView.vue"), meta: { title: "对局" } },
    { path: "/live", redirect: "/game" },
    { path: "/matches", name: "matches", component: () => import("../views/MatchesView.vue"), meta: { title: "战绩" } },
    { path: "/champions", name: "champions", component: () => import("../views/ChampionsView.vue"), meta: { title: "英雄" } },
    { path: "/automation", name: "automation", component: () => import("../views/AutomationView.vue"), meta: { title: "自动化" } },
    { path: "/history", name: "history", component: () => import("../views/HistoryView.vue"), meta: { title: "历史" } },
    { path: "/friends", name: "friends", component: () => import("../views/FriendsView.vue"), meta: { title: "好友工具" } },
    { path: "/settings", name: "settings", component: () => import("../views/SettingsView.vue"), meta: { title: "设置" } },
  ],
});

router.afterEach((route) => {
  document.title = `${String(route.meta.title)} · 桌上英雄联盟`;
});

export default router;
