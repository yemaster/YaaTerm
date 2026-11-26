<script setup lang="ts">
import { withBase } from 'vitepress'
import terminalWindow from '../../../docs/terminal.png'

const groups = [
  { title: '使用指南', links: [
    { label: '安装与更新', link: '/guide/start.html', detail: 'macOS 13+' },
    { label: '标签页与分屏', link: '/guide/workspace.html', detail: '⌘T / ⌘D' },
    { label: '阅读与搜索输出', link: '/guide/output.html', detail: 'ls · cat · nl' },
    { label: '外观与回滚', link: '/guide/settings.html', detail: '字体、配色与历史记录' },
  ] },
  { title: 'AI 工具', links: [
    { label: '连接模型服务', link: '/ai/service.html', detail: 'API 设置' },
    { label: '命令解释', link: '/ai/explain.html', detail: '⇧⌘E' },
    { label: '在终端运行 Agent', link: '/ai/agent.html', detail: '⌘J' },
  ] },
]
</script>

<template>
  <div class="home-wrap">
    <section class="intro" aria-labelledby="product">
      <div class="intro-copy">
        <h1 id="product">YaaTerm<span class="cursor" aria-hidden="true"></span></h1>
        <p>Mac 上的原生终端。分屏写代码，按列读输出，在当前 shell 里使用 Agent。</p>
        <div class="intro-actions">
          <a class="primary-action" href="https://github.com/yemaster/YaaTerm/releases/latest">下载 Mac 版 <span aria-hidden="true">↓</span></a>
          <a class="guide-action" :href="withBase('/guide/start.html')">阅读文档 <span aria-hidden="true">→</span></a>
        </div>
        <p class="requirements">macOS 13 及以上 · Apple Silicon 与 Intel</p>
      </div>
      <figure class="terminal-stage">
        <img :src="terminalWindow" width="1580" height="760" fetchpriority="high" alt="YaaTerm 中的文件列表和带行号的 Python 代码">
      </figure>
    </section>
    <div class="manual-index">
      <section v-for="group in groups" :key="group.title">
        <h2>{{ group.title }}</h2>
        <ul>
          <li v-for="entry in group.links" :key="entry.link">
            <a :href="withBase(entry.link)"><span>{{ entry.label }}</span><small>{{ entry.detail }}</small><span class="link-arrow" aria-hidden="true">→</span></a>
          </li>
        </ul>
      </section>
    </div>
    <nav class="more-links" aria-label="参考与反馈">
      <a :href="withBase('/reference/shortcuts.html')">快捷键</a>
      <a :href="withBase('/reference/performance.html')">性能实测</a>
      <a href="https://github.com/yemaster/YaaTerm/releases">更新日志</a>
      <a href="https://github.com/yemaster/YaaTerm/issues">问题反馈</a>
    </nav>
  </div>
</template>
