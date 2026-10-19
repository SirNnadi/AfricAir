Files under dist/assets/ contain content hashes to support cache busting and efficient browser caching. When the application changes, the build generates new filenames, ensuring browsers request updated assets rather than serving outdated cached versions. Without hashes, The user could continue seeing outdated content despite your successful deployment.
Even worse, if old JavaScript references resources that have changed or been removed, parts of your application could fail. Content hashing improves deployment reliability and allows static assets to be cached aggressively.
-------------------------------------------------------------------------------------------------------------------------------
tsc -b: Checking TypeScript code for type errors, Building TypeScript projects according to their tsconfig.json configurations, Processing project references and build dependencies, Preventing the next command from running if compilation fails.
vite build: Bundling JavaScript and CSS, Minifying code to reduce file sizes, Optimizing production assets, Generating content-hashed filenames for caching, Creating the production-ready dist/ directory
---------------------------------------------------------------------------------------------------------------------------------
--frozen-lockfile ensures pnpm installs the exact dependency versions recorded in the lockfile without modifying it. If I delete pnpm-lock.yaml and reinstall, pnpm resolves dependencies again, potentially selecting newer versions and generating a different dependency tree. This is dangerous in CI because identical application code could produce different builds, causing unexpected failures, security issues, or production regressions. Using a frozen lockfile makes builds more predictable and reproducible.
---------------------------------------------------------------------------------------------------------------------------------
Both manualChunks and chunkSizeWarningLimit are Vite build configuration options that help you manage JavaScript bundle sizes and understand potential performance issues.
manualChunks - controls how JavaScript code is divided into separate output files during production builds.
chunkSizeWarningLimit - controls when Vite displays a warning about large JavaScript chunks.
Largest - dist/assets/pdf-CyMW5xlM.js       584.78 kB │ gzip: 175.43 kB
A user with a slow mobile connection may wait significantly longer for large JavaScript files to download.
Large chunks can cause:
- Slow initial page loading if the chunk is required immediately.
- Delayed interactivity because browsers must parse and execute JavaScript.
- Higher mobile data consumption.
- Poor user experience when users have weak connections.
-----------------------------------------------------------------------------------------------------------------------------------
pnpm dev should never be used to serve production traffic because it starts Vite's development server, which is designed for local development rather than secure, optimized, reliable production hosting.
Three main reasons
1. Security risks: Vite's development server exposes development-specific functionality, including Hot Module Replacement (HMR), development endpoints, and potentially source code or debugging information. It is not designed to be exposed directly to untrusted production traffic.
2. Poor performance: pnpm dev serves application modules for development rather than using the optimized production bundle. It does not provide the same production minification, bundling, and asset optimization performed by vite build. This can increase network requests, download sizes, and page-loading times.
3. Production reliability: The development server prioritizes fast code changes and debugging rather than production operations. It is not intended to provide the hardened serving configuration, caching policies, and operational reliability expected from a production web server.
-----------------------------------------------------------------------------------------------------------------------------------
1.4M    dist/
gzipped = 460800# test

