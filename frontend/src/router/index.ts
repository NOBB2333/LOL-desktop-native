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
    // 「工具箱」页已拆成一键领取（自动化页）与客户端急救（对局页右栏）。
    // 这里留一条重定向：老书签/历史记录还会带着 #/toolkit，不接的话会落到空内容，
    // 面包屑还会显示字面量 "undefined"（`String(route.meta.title)`）。
    { path: "/toolkit", redirect: "/automation" },
    { path: "/history", name: "history", component: () => import("../views/HistoryView.vue"), meta: { title: "历史" } },
    { path: "/friends", name: "friends", component: () => import("../views/FriendsView.vue"), meta: { title: "好友工具" } },
    { path: "/client", name: "client", component: () => import("../views/ClientView.vue"), meta: { title: "客户端" } },
    { path: "/settings", name: "settings", component: () => import("../views/SettingsView.vue"), meta: { title: "设置" } },
  ],
});

router.afterEach((route) => {
  document.title = `${String(route.meta.title)} · 桌上英雄联盟`;
});

export default router;
