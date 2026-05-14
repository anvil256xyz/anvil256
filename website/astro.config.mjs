// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import tailwind from "@astrojs/tailwind";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";

// https://astro.build/config
export default defineConfig({
  site: "https://anvil256.xyz",
  output: "static",
  markdown: {
    remarkPlugins: [remarkMath],
    rehypePlugins: [rehypeKatex],
  },
  integrations: [
    starlight({
      title: "Anvil256",
      description:
        "Fair-launch 21M-cap ERC-20 with Keccak-Cascade PoW, protocol-owned liquidity, no dev premine, no presale, and no backend.",
      logo: {
        src: "./src/assets/logo.svg",
        replacesTitle: false,
      },
      head: [
        {
          tag: "link",
          attrs: {
            rel: "icon",
            type: "image/png",
            href: "/logo.svg",
          },
        },
      ],
      social: {
        github: "https://github.com/anvil256/anvil256",
      },
      sidebar: [
        {
          label: "Start here",
          items: [
            { label: "Overview", link: "/" },
            { label: "Whitepaper", link: "/whitepaper" },
            { label: "Mining guide", link: "/mining-guide" },
          ],
        },
        {
          label: "Spec",
          items: [
            { label: "Tokenomics", link: "/tokenomics" },
            { label: "Architecture", link: "/architecture" },
            { label: "Math Reference", link: "/math" },
            { label: "Security", link: "/security" },
            { label: "Roadmap", link: "/roadmap" },
          ],
        },
        {
          label: "Operations",
          items: [
            { label: "Build from source", link: "/build" },
            { label: "Deployment", link: "/deployment" },
          ],
        },
        {
          label: "Live",
          items: [
            { label: "Live stats", link: "/stats" },
            { label: "Downloads", link: "/download" },
          ],
        },
      ],
      customCss: [
        // KaTeX font + layout CSS — must come before global so it can be overridden
        "katex/dist/katex.min.css",
        "./src/styles/global.css",
      ],
    }),
    tailwind({ applyBaseStyles: false }),
  ],
  // No backend: every page must be statically renderable.
  // viem runs entirely client-side from the visitor's chosen RPC.
});
