import { defineConfig } from 'vitepress'

const base = process.env.DOCS_BASE || '/YaaTerm/'
const repository = 'https://github.com/yemaster/YaaTerm'
const sidebar = [
  { text: '使用指南', items: [
    { text: '安装与更新', link: '/guide/start' },
    { text: '标签页与分屏', link: '/guide/workspace' },
    { text: '阅读与搜索输出', link: '/guide/output' },
    { text: '外观与回滚', link: '/guide/settings' },
  ] },
  { text: 'AI 工具', items: [
    { text: '连接模型服务', link: '/ai/service' },
    { text: '命令解释', link: '/ai/explain' },
    { text: '在终端运行 Agent', link: '/ai/agent' },
  ] },
  { text: '参考', items: [
    { text: '快捷键', link: '/reference/shortcuts' },
    { text: '性能实测', link: '/reference/performance' },
  ] },
]

export default defineConfig({
  lang: 'zh-CN',
  title: 'YaaTerm',
  description: 'YaaTerm 的 macOS 安装、使用指南与命令参考。',
  srcDir: 'src',
  base,
  sitemap: { hostname: (process.env.DOCS_ORIGIN || 'https://yemaster.github.io') + base },
  head: [['link', { rel: 'icon', href: base + 'yaaterm.png', type: 'image/png' }]],
  markdown: { codeCopyButtonTitle: '复制命令' },
  themeConfig: {
    logo: '/yaaterm.png',
    nav: [
      { text: '使用指南', link: '/guide/start', activeMatch: '^/guide/' },
      { text: 'AI 工具', link: '/ai/service', activeMatch: '^/ai/' },
      { text: '参考', link: '/reference/shortcuts', activeMatch: '^/reference/' },
    ],
    sidebar,
    socialLinks: [{ icon: 'github', link: repository, ariaLabel: 'GitHub 仓库' }],
    outline: { level: [2, 3], label: '本页内容' },
    docFooter: { prev: '上一页', next: '下一页' },
    sidebarMenuLabel: '目录', returnToTopLabel: '回到顶部', skipToContentLabel: '跳至正文',
    darkModeSwitchLabel: '外观', darkModeSwitchTitle: '切换到深色', lightModeSwitchTitle: '切换到浅色',
    notFound: { title: '找不到这一页', quote: '可以搜索文档，或回到首页。', linkText: '回到首页', linkLabel: '回到首页' },
    search: { provider: 'local', options: {
      translations: {
        button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
        modal: { noResultsText: '没有匹配的文档', resetButtonTitle: '清空搜索', displayDetails: '显示摘要',
          backButtonTitle: '关闭搜索', footer: { selectText: '打开', navigateText: '选择', closeText: '关闭' } },
      },
      miniSearch: { options: {
        tokenize: (text: string) => Array.from(new Intl.Segmenter('zh-CN', { granularity: 'word' }).segment(text))
          .filter(word => word.isWordLike).map(word => word.segment.toLowerCase()),
      } },
    } },
  },
})
