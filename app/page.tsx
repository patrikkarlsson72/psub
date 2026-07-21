"use client";

/* eslint-disable @next/next/no-img-element -- vinext serves this local brand asset directly. */

import { useEffect, useRef } from "react";

const stages = ["Inspect", "Configure", "Compile", "Package", "Prove"];

function GridField() {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const context = canvas.getContext("2d");
    if (!context) return;

    let frame = 0;
    let width = 0;
    let height = 0;
    let pointerX = 0.62;
    let pointerY = 0.42;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const resize = () => {
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      width = canvas.clientWidth;
      height = canvas.clientHeight;
      canvas.width = width * ratio;
      canvas.height = height * ratio;
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
    };

    const move = (event: PointerEvent) => {
      pointerX = event.clientX / window.innerWidth;
      pointerY = event.clientY / window.innerHeight;
    };

    const draw = (time: number) => {
      context.clearRect(0, 0, width, height);
      const gap = width < 700 ? 34 : 44;
      const drift = reduced ? 0 : time * 0.00009;

      for (let x = -gap; x < width + gap; x += gap) {
        for (let y = -gap; y < height + gap; y += gap) {
          const wave = Math.sin(x * 0.012 + y * 0.01 + drift * 10);
          const dx = x / width - pointerX;
          const dy = y / height - pointerY;
          const proximity = Math.max(0, 1 - Math.sqrt(dx * dx + dy * dy) * 2.4);
          const radius = 0.8 + proximity * 2.4 + wave * 0.25;
          context.beginPath();
          context.arc(x + wave * 4, y + wave * 3, radius, 0, Math.PI * 2);
          context.fillStyle = `rgba(26, 214, 255, ${0.14 + proximity * 0.5})`;
          context.fill();
        }
      }

      if (!reduced) frame = requestAnimationFrame(draw);
    };

    resize();
    draw(0);
    if (!reduced) frame = requestAnimationFrame(draw);
    window.addEventListener("resize", resize);
    window.addEventListener("pointermove", move, { passive: true });
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", resize);
      window.removeEventListener("pointermove", move);
    };
  }, []);

  return <canvas ref={canvasRef} className="grid-field" aria-hidden="true" />;
}

export default function Home() {
  useEffect(() => {
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) entry.target.classList.add("is-visible");
        });
      },
      { threshold: 0.14 },
    );
    document.querySelectorAll("[data-reveal]").forEach((node) => observer.observe(node));
    return () => observer.disconnect();
  }, []);

  return (
    <main>
      <GridField />
      <div className="noise" aria-hidden="true" />

      <header className="site-header">
        <a className="brand" href="#top" aria-label="PSUB home">
          <img src="/psub-logo.png" alt="PSUB — Python Security Update Builder" width="1621" height="861" />
        </a>
        <nav aria-label="Primary navigation">
          <a href="#pipeline">Pipeline</a>
          <a href="#proof">Evidence</a>
          <a href="#start">Quick start</a>
        </nav>
        <a className="header-cta" href="#start">Build securely <span>↗</span></a>
      </header>

      <section className="hero" id="top">
        <div className="hero-copy">
          <div className="eyebrow"><span className="status-dot" /> Windows-native release engineering</div>
          <h1>Security releases.<br /><em>Built with proof.</em></h1>
          <p className="hero-lede">
            PSUB turns complex CPython security builds into a controlled, repeatable Windows workflow—from source inspection to verifiable release evidence.
          </p>
          <div className="hero-actions">
            <a className="button button-primary" href="#pipeline"><span>Explore the pipeline</span><b>↓</b></a>
            <a className="button button-ghost" href="#start">Open quick start</a>
          </div>
        </div>

        <div className="hero-system" aria-label="Animated five-stage PSUB build pipeline">
          <div className="orbit orbit-one" />
          <div className="orbit orbit-two" />
          <div className="system-card">
            <div className="system-topline">
              <span>PSUB / PIPELINE</span>
              <span className="live"><i /> ACTIVE</span>
            </div>
            <div className="core-mark">
              <span className="core-ring" />
              <span className="core-ring core-ring-two" />
              <b>PS</b>
              <small>SECURE BUILD CORE</small>
            </div>
            <div className="pipeline-list">
              {stages.map((stage, index) => (
                <div className={`pipeline-row stage-${index + 1}`} key={stage}>
                  <span>0{index + 1}</span><b>{stage}</b><i /><em>{index === 4 ? "ready" : "verified"}</em>
                </div>
              ))}
            </div>
            <div className="system-footer">
              <span>SHA256</span><code>7F3A · 91C2 · 0B8E</code><strong>100%</strong>
            </div>
          </div>
          <div className="float-label label-one">EVIDENCE / ON</div>
          <div className="float-label label-two">WIN · X64</div>
        </div>

        <div className="hero-index" aria-hidden="true">01</div>
        <div className="scroll-cue"><span /> SCROLL TO DECODE</div>
      </section>

      <section className="signal-bar" aria-label="Key capabilities">
        <div><strong>3.10—3.12</strong><span>Supported Python lines</span></div>
        <div><strong>1 WORKFLOW</strong><span>CLI and local web UI</span></div>
        <div><strong>SHA256</strong><span>Evidence-grade checksums</span></div>
        <div><strong>WINDOWS</strong><span>Native toolchain aware</span></div>
      </section>

      <section className="manifesto" data-reveal>
        <p className="section-kicker">/ WHY PSUB</p>
        <p className="manifesto-line">Patch releases are urgent.</p>
        <p className="manifesto-line muted">Your process shouldn&apos;t be improvised.</p>
      </section>

      <section className="pipeline-section" id="pipeline">
        <div className="section-heading" data-reveal>
          <div>
            <p className="section-kicker">/ CONTROLLED PIPELINE</p>
            <h2>From source tree<br />to trusted artifact.</h2>
          </div>
          <p>PSUB codifies the brittle parts of Windows release engineering into one observable flow, with the right branch for every supported Python line.</p>
        </div>

        <div className="stage-grid">
          {[
            ["01", "Preflight", "Detect Visual Studio, Windows SDK, bootstrap Python, WiX, and .NET requirements before the expensive work begins.", "ENVIRONMENT READY"],
            ["02", "Build", "Configure the correct documentation and MSI path for Python 3.10, 3.11, or 3.12—then compile with the native toolchain.", "TOOLCHAIN LOCKED"],
            ["03", "Collect", "Gather release installers, documentation output, metadata, and logs into a predictable release structure.", "ARTIFACTS INDEXED"],
            ["04", "Prove", "Generate checksums, environment details, pip state, and a presentation-ready HTML evidence summary automatically.", "EVIDENCE SEALED"],
          ].map(([number, title, body, badge], index) => (
            <article className="stage-card" data-reveal key={number} style={{ "--delay": `${index * 80}ms` } as React.CSSProperties}>
              <div className="stage-number">{number}</div>
              <div className="stage-icon" aria-hidden="true"><span /><i /></div>
              <h3>{title}</h3>
              <p>{body}</p>
              <div className="stage-badge"><i /> {badge}</div>
            </article>
          ))}
        </div>
      </section>

      <section className="proof-section" id="proof">
        <div className="proof-copy" data-reveal>
          <p className="section-kicker">/ FORENSIC BY DEFAULT</p>
          <h2>Every release<br />leaves a trail.</h2>
          <p>Evidence capture is part of the build, not an afterthought. PSUB records the state you need to validate, review, and hand off a security release with confidence.</p>
          <ul>
            <li><span>✓</span> SHA256 for collected artifacts</li>
            <li><span>✓</span> Build and source metadata</li>
            <li><span>✓</span> Python environment snapshot</li>
            <li><span>✓</span> Shareable HTML summary</li>
          </ul>
        </div>

        <div className="proof-console" data-reveal>
          <div className="console-head"><span><i /><i /><i /></span><b>release-evidence / summary</b><em>VERIFIED</em></div>
          <div className="console-body">
            <div className="hash-visual"><div className="hash-pulse" /><span>BUILD<br />PROOF</span></div>
            <div className="console-lines">
              <p><span>release</span><b>Python-3.12.x</b></p>
              <p><span>platform</span><b>windows-x64</b></p>
              <p><span>artifacts</span><b>indexed</b></p>
              <p><span>checksums</span><b className="cyan">verified</b></p>
              <p><span>status</span><b className="green">● ready</b></p>
            </div>
          </div>
          <div className="checksum"><span>SHA256</span><code>e3b0c44298fc1c149afbf4c8996fb924...</code><b>COPY</b></div>
        </div>
      </section>

      <section className="version-section" data-reveal>
        <div>
          <p className="section-kicker">/ VERSION INTELLIGENCE</p>
          <h2>One interface.<br />Three release lines.</h2>
        </div>
        <div className="version-stack">
          <article><b>3.10</b><span>LEGACY MSI PATH</span><p>CHM documentation, WiX, and .NET 3.5 requirements handled explicitly.</p><i>SUPPORTED</i></article>
          <article><b>3.11</b><span>SECURITY RELEASE</span><p>HTML documentation and Windows installer packaging selected automatically.</p><i>SUPPORTED</i></article>
          <article><b>3.12</b><span>SECURITY RELEASE</span><p>Modern bootstrap and toolchain flow with consistent artifact collection.</p><i>SUPPORTED</i></article>
        </div>
      </section>

      <section className="quickstart" id="start">
        <div className="quickstart-copy" data-reveal>
          <p className="section-kicker">/ START THE BUILD</p>
          <h2>One command.<br />Full control.</h2>
          <p>Point PSUB at an extracted CPython source tree. It validates the machine, selects the release path, runs the build, and captures the evidence.</p>
          <div className="mode-pills"><span>CLI</span><span>LOCAL WEB UI</span><span>NO CLOUD REQUIRED</span></div>
        </div>
        <div className="terminal" data-reveal>
          <div className="terminal-bar"><span>PS</span><p>PowerShell · PSUB</p><b>—　□　×</b></div>
          <pre><code><span className="prompt">PS C:\PSUB&gt;</span> .\Script\Build-PythonRelease.ps1 `<br />  <span className="flag">-SourcePath</span> <span className="string">&quot;C:\src\Python-3.12.x\Python-3.12.x&quot;</span><br /><br /><span className="success">✓</span> Prerequisites verified<br /><span className="success">✓</span> Release toolchain configured<br /><span className="success">✓</span> Artifacts collected<br /><span className="success">✓</span> Evidence bundle captured<br /><br /><span className="terminal-ready">READY / release output is sealed</span></code></pre>
        </div>
      </section>

      <section className="final-cta" data-reveal>
        <div className="cta-glow" />
        <p className="section-kicker">/ SHIP THE PATCH. KEEP THE PROOF.</p>
        <h2>Build the release<br />you can stand behind.</h2>
        <a className="button button-primary" href="#start"><span>Open the quick start</span><b>↑</b></a>
      </section>

      <footer>
        <a className="footer-brand" href="#top"><img src="/psub-logo.png" alt="PSUB" width="1621" height="861" /></a>
        <p>Python Security Update Builder<br />Windows release engineering, systematized.</p>
        <div><a href="#pipeline">Pipeline</a><a href="#proof">Evidence</a><a href="#start">Quick start</a></div>
        <span>PSUB / OPEN TOOLING</span>
      </footer>
    </main>
  );
}
