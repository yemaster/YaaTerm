# YaaTerm 文档站

在仓库的 `website/` 目录运行，需要 Node.js 24.14 或更新版本。

```sh
npm ci
npm run dev
```

打开命令行打印的本机地址，路径为 `/YaaTerm/`。页面在 `src/`，导航与侧栏在 `.vitepress/config.ts`。首页直接引用仓库中的终端截图，性能页引用 `docs/performance.md`。

```sh
npm run build
npm run preview
```

构建会检查生成页面的内部链接和锚点，静态文件输出至 `.vitepress/dist/`。合入 `master` 后，文档工作流将站点部署至 GitHub Pages。拉取请求只运行构建检查。
