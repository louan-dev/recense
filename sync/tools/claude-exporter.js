(async () => {
  'use strict';

  const API = '/api';
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  // ============================================================
  // Helpers
  // ============================================================

  function asArray(v) {
    if (Array.isArray(v)) return v;
    if (v && Array.isArray(v.data)) return v.data;
    if (v && Array.isArray(v.items)) return v.items;
    if (v && Array.isArray(v.results)) return v.results;
    return [];
  }

  async function fetchJSON(url, optional = false) {
    const r = await fetch(url, {
      credentials: 'include',
      headers: { Accept: 'application/json' },
    });

    if (!r.ok) {
      if (optional && (r.status === 403 || r.status === 404)) return null;
      const body = await r.text().catch(() => '');
      throw new Error(
        `${r.status} ${r.statusText}: ${url}` +
        (body ? `\n${body.slice(0, 500)}` : '')
      );
    }

    return r.json();
  }

  async function fetchBlob(url, optional = false) {
    const r = await fetch(url, { credentials: 'include' });

    if (!r.ok) {
      if (optional && (r.status === 403 || r.status === 404)) return null;
      throw new Error(`${r.status} ${r.statusText}: ${url}`);
    }

    return r.blob();
  }

  function absUrl(url) {
    if (!url) return null;
    try {
      return new URL(url, location.origin).href;
    } catch {
      return url;
    }
  }

  function safeName(value, fallback = 'Untitled', max = 180) {
    let s = String(value || fallback)
      .normalize('NFC')
      .replace(/[\u0000-\u001f\u007f]/g, '')
      .replace(/[\/\\:*?"<>|]/g, '–')
      .trim();

    if (!s) s = fallback;
    if (s.length > max) s = s.slice(0, max).trim();

    return s;
  }

  function makeUniqueNamer() {
    const used = new Map();

    return name => {
      const clean = safeName(name);
      const key = clean.toLocaleLowerCase();

      if (!used.has(key)) {
        used.set(key, 1);
        return clean;
      }

      const n = used.get(key) + 1;
      used.set(key, n);

      const dot = clean.lastIndexOf('.');
      return dot > 0
        ? `${clean.slice(0, dot)} (${n})${clean.slice(dot)}`
        : `${clean} (${n})`;
    };
  }

  async function getDir(parent, name) {
    return parent.getDirectoryHandle(safeName(name), { create: true });
  }

  async function writeBlob(dir, name, blob) {
    const handle = await dir.getFileHandle(safeName(name), { create: true });
    const writer = await handle.createWritable();
    await writer.write(blob);
    await writer.close();
  }

  async function writeText(dir, name, text) {
    await writeBlob(
      dir,
      name,
      new Blob([text ?? ''], { type: 'text/plain;charset=utf-8' })
    );
  }

  function iso(value) {
    if (!value) return '';
    const d = new Date(value);
    return Number.isNaN(d.valueOf()) ? String(value) : d.toISOString();
  }

  function firstString(...values) {
    for (const v of values) {
      if (typeof v === 'string' && v.trim()) return v;
    }
    return '';
  }

  function memoryText(memory) {
    if (!memory) return '';
    if (typeof memory === 'string') return memory;

    return firstString(
      memory.memory,
      memory.content,
      memory.text,
      memory.value,
      memory.summary
    );
  }

  function longestBacktickRun(text) {
    return (String(text || '').match(/`+/g) || [])
      .reduce((m, run) => Math.max(m, run.length), 0);
  }

  function fencedText(text) {
    const fence = '`'.repeat(Math.max(3, longestBacktickRun(text) + 1));
    return `${fence}text\n${text}\n${fence}`;
  }

  function extensionFromMime(type) {
    const t = String(type || '').toLowerCase().split(';')[0].trim();

    const map = {
      'image/png': '.png',
      'image/jpeg': '.jpg',
      'image/webp': '.webp',
      'image/gif': '.gif',
      'image/svg+xml': '.svg',
      'application/pdf': '.pdf',
      'application/json': '.json',
      'text/plain': '.txt',
      'text/markdown': '.md',
      'text/html': '.html',
      'text/csv': '.csv',
    };

    return map[t] || '';
  }

  function inferArtifactExtension(input, content) {
    const kind = String(
      input?.type ||
      input?.language ||
      input?.mime_type ||
      ''
    ).toLowerCase();

    const map = {
      'text/markdown': '.md',
      markdown: '.md',
      md: '.md',

      'text/plain': '.txt',
      text: '.txt',
      txt: '.txt',

      'text/html': '.html',
      html: '.html',

      'image/svg+xml': '.svg',
      svg: '.svg',

      'application/json': '.json',
      json: '.json',

      javascript: '.js',
      js: '.js',

      typescript: '.ts',
      ts: '.ts',

      jsx: '.jsx',
      tsx: '.tsx',

      python: '.py',
      py: '.py',

      css: '.css',
      csv: '.csv',
      xml: '.xml',
      sql: '.sql',
      bash: '.sh',
      shell: '.sh',
    };

    if (map[kind]) return map[kind];

    const s = String(content || '').trimStart().toLowerCase();
    if (s.startsWith('<svg')) return '.svg';
    if (s.startsWith('<!doctype html') || s.startsWith('<html')) return '.html';

    return '.md';
  }

  // ============================================================
  // Project discovery
  // ============================================================

  async function discoverProjects() {
    const orgs = asArray(await fetchJSON(`${API}/organizations`));
    const found = [];

    for (const org of orgs) {
      if (!org?.uuid) continue;

      try {
        const data = await fetchJSON(
          `${API}/organizations/${org.uuid}/projects` +
          `?include_harmony_projects=true&limit=100`
        );

        for (const project of asArray(data)) {
          if (project?.uuid) found.push({ org, project });
        }
      } catch (e) {
        console.warn('Could not list projects for org', org.uuid, e);
      }
    }

    return found;
  }

  function projectIdFromUrl() {
    return location.pathname.match(/\/projects?\/([0-9a-f-]{20,})/i)?.[1] || null;
  }

  function chooseProject(projects) {
    if (!projects.length) throw new Error('No Claude projects found.');

    const current = projectIdFromUrl();
    if (current) {
      const match = projects.find(x => x.project.uuid === current);
      if (match) return match;
    }

    if (projects.length === 1) return projects[0];

    const list = projects
      .map((x, i) => `${i + 1}. ${x.project.name || '(unnamed project)'}`)
      .join('\n');

    const answer = prompt(
      `Which project should be exported?\n\n${list}\n\nEnter a number:`,
      '1'
    );

    if (answer == null) return null;

    const idx = Number(answer) - 1;
    if (!Number.isInteger(idx) || idx < 0 || idx >= projects.length) {
      throw new Error('Invalid project number.');
    }

    return projects[idx];
  }

  // ============================================================
  // Conversation tree
  // ============================================================

  function activeBranch(messages, leafUuid) {
    if (!leafUuid || !Array.isArray(messages)) return messages || [];

    const byId = new Map(
      messages
        .filter(m => m?.uuid)
        .map(m => [m.uuid, m])
    );

    const branch = [];
    const seen = new Set();
    let id = leafUuid;

    while (id && byId.has(id) && !seen.has(id)) {
      seen.add(id);
      const m = byId.get(id);
      branch.push(m);
      id = m.parent_message_uuid;
    }

    return branch.length ? branch.reverse() : messages;
  }

  function extractedTextItems(message) {
    const out = [];

    for (const obj of [
      ...asArray(message?.attachments),
      ...asArray(message?.files),
    ]) {
      if (
        typeof obj?.extracted_content === 'string' &&
        obj.extracted_content.length
      ) {
        out.push({
          name: obj.file_name || obj.name || 'Attached text',
          text: obj.extracted_content,
        });
      }
    }

    return out;
  }

  // ============================================================
  // Citations / sources
  // ============================================================

  function citationLinesFromCitation(c) {
    const lines = [];
    if (!c || typeof c !== 'object') return lines;

    if (c.url) {
      const title = firstString(c.title, c.name, c.url);
      const via = c.origin_tool_name ? ` — via ${c.origin_tool_name}` : '';
      lines.push(`- [${title}](${c.url})${via}`);
    }

    for (const src of asArray(c.sources)) {
      if (typeof src === 'string') {
        lines.push(`- ${src}`);
      } else if (src && typeof src === 'object') {
        if (src.url) {
          const title = firstString(src.title, src.name, src.url);
          lines.push(`- [${title}](${src.url})`);
        }
      }
    }

    if (!c.url) {
      const docTitle = firstString(
        c.document_title,
        c.title,
        c.file_name,
        c.document_id,
        c.file_id
      );

      if (docTitle) {
        let loc = '';

        if (Number.isFinite(c.page_number)) {
          loc = ` — page ${c.page_number}`;
        } else if (
          Number.isFinite(c.start_page_number) ||
          Number.isFinite(c.end_page_number)
        ) {
          const a = c.start_page_number ?? c.end_page_number;
          const b = c.end_page_number ?? c.start_page_number;
          loc = a === b ? ` — page ${a}` : ` — pages ${a}–${b}`;
        } else if (
          Number.isFinite(c.start_index) ||
          Number.isFinite(c.end_index)
        ) {
          const a = c.start_index ?? '?';
          const b = c.end_index ?? '?';
          loc = ` — characters ${a}–${b}`;
        } else if (
          Number.isFinite(c.start_char_index) ||
          Number.isFinite(c.end_char_index)
        ) {
          const a = c.start_char_index ?? '?';
          const b = c.end_char_index ?? '?';
          loc = ` — characters ${a}–${b}`;
        }

        lines.push(`- ${docTitle}${loc}`);
      }
    }

    return lines;
  }

  function collectMessageSourceLines(message) {
    const lines = [];

    for (const b of asArray(message?.content)) {
      if (b?.type !== 'text') continue;

      for (const c of asArray(b.citations)) {
        lines.push(...citationLinesFromCitation(c));
      }
    }

    return [...new Set(lines)];
  }

  // ============================================================
  // Markdown chat
  // ============================================================

  function renderChatMarkdown(conversation, messages, projectName) {
    const title =
      conversation.name ||
      conversation.title ||
      'Untitled chat';

    const created =
      conversation.created_at ||
      messages[0]?.created_at ||
      '';

    const md = [
      `# ${title}`,
      '',
      `Project: ${projectName}`,
      '',
    ];

    if (created) md.push(`Created: ${iso(created)}`, '');

    for (const m of messages) {
      const who = m.sender === 'human' ? 'User' : 'Claude';
      const ts = iso(m.created_at);

      md.push(`## ${who}${ts ? ` — ${ts}` : ''}`, '');

      const blocks = Array.isArray(m.content) ? m.content : [];
      let wroteText = false;

      for (const b of blocks) {
        if (!b || typeof b !== 'object') continue;

        if (
          b.type === 'text' &&
          typeof b.text === 'string' &&
          b.text.length
        ) {
          md.push(b.text, '');
          wroteText = true;
        }
      }

      if (
        !wroteText &&
        typeof m.text === 'string' &&
        m.text.length
      ) {
        md.push(m.text, '');
      }

      const extracted = extractedTextItems(m);
      const extractedNames = new Set(extracted.map(x => x.name));

      for (const item of extracted) {
        md.push(
          `### Attached text — ${item.name}`,
          '',
          fencedText(item.text),
          ''
        );
      }

      const names = new Set();

      for (const a of asArray(m.attachments)) {
        if (a?.file_name) names.add(a.file_name);
      }

      for (const f of asArray(m.files)) {
        if (f?.file_name) names.add(f.file_name);
      }

      for (const name of names) {
        if (!extractedNames.has(name)) {
          md.push(`> Attachment: ${name}`, '');
        }
      }

      if (m.sender !== 'human') {
        const sources = collectMessageSourceLines(m);

        if (sources.length) {
          md.push(
            '### Sources',
            '',
            ...sources,
            ''
          );
        }
      }

      if (m.compaction_summary) {
        const summary =
          typeof m.compaction_summary === 'string'
            ? m.compaction_summary
            : firstString(
                m.compaction_summary.summary,
                m.compaction_summary.text,
                m.compaction_summary.content
              );

        if (summary) {
          md.push(
            '### Claude compaction summary',
            '',
            summary,
            ''
          );
        }
      }
    }

    return md
      .join('\n')
      .replace(/\n{4,}/g, '\n\n\n')
      .trim() + '\n';
  }

  // ============================================================
  // Reconstruct final Claude artifacts
  // ============================================================

  function replaceExactlyOnce(text, oldStr, newStr) {
    const first = text.indexOf(oldStr);
    if (first < 0) return { ok: false, text, reason: 'old_str not found' };

    const second = text.indexOf(oldStr, first + oldStr.length);

    if (second >= 0) {
      return {
        ok: false,
        text,
        reason: 'old_str appears more than once',
      };
    }

    return {
      ok: true,
      text:
        text.slice(0, first) +
        newStr +
        text.slice(first + oldStr.length),
    };
  }

  function replayArtifacts(messages) {
    const artifacts = new Map();
    let anonymousCounter = 0;

    for (const m of messages) {
      for (const block of asArray(m?.content)) {
        if (
          block?.type !== 'tool_use' ||
          block?.name !== 'artifacts' ||
          !block.input ||
          typeof block.input !== 'object'
        ) {
          continue;
        }

        const input = block.input;
        const command = String(input.command || 'create').toLowerCase();

        let id = firstString(
          input.id,
          input.artifact_id,
          input.uuid,
          input.version_uuid
        );

        if (!id) {
          id = `anonymous-artifact-${++anonymousCounter}`;
        }

        let state = artifacts.get(id);

        if (!state) {
          state = {
            id,
            title: firstString(input.title, id),
            type: firstString(input.type, input.mime_type),
            language: firstString(input.language),
            content: '',
            warnings: [],
          };

          artifacts.set(id, state);
        }

        if (input.title) state.title = input.title;
        if (input.type) state.type = input.type;
        if (input.mime_type) state.type = input.mime_type;
        if (input.language) state.language = input.language;

        if (command === 'create') {
          if (typeof input.content === 'string') {
            state.content = input.content;
          } else if (typeof input.new_str === 'string') {
            state.content = input.new_str;
          }

          continue;
        }

        if (command === 'rewrite') {
          if (typeof input.content === 'string') {
            state.content = input.content;
          } else if (typeof input.new_str === 'string') {
            state.content = input.new_str;
          } else {
            state.warnings.push(
              'rewrite command had no content/new_str'
            );
          }

          continue;
        }

        if (command === 'update') {
          if (
            typeof input.old_str === 'string' &&
            typeof input.new_str === 'string'
          ) {
            const replaced = replaceExactlyOnce(
              state.content,
              input.old_str,
              input.new_str
            );

            if (replaced.ok) {
              state.content = replaced.text;
            } else if (typeof input.content === 'string') {
              state.content = input.content;

              state.warnings.push(
                `update patch could not be applied (${replaced.reason}); used full content fallback`
              );
            } else {
              state.warnings.push(
                `update patch could not be applied: ${replaced.reason}`
              );
            }
          } else if (typeof input.content === 'string') {
            state.content = input.content;
          } else {
            state.warnings.push(
              'update command had no usable patch/content'
            );
          }

          continue;
        }

        if (typeof input.content === 'string') {
          state.content = input.content;

          state.warnings.push(
            `unknown command "${command}"; used supplied content`
          );
        } else {
          state.warnings.push(
            `unknown command "${command}"`
          );
        }
      }
    }

    return [...artifacts.values()]
      .filter(a => a.content.length);
  }

  async function saveReconstructedArtifacts(
    messages,
    outputsDir,
    outputUnique
  ) {
    const artifacts = replayArtifacts(messages);

    for (const artifact of artifacts) {
      const stem = safeName(
        artifact.title ||
        artifact.id ||
        'artifact'
      );

      const ext = inferArtifactExtension(
        {
          type: artifact.type,
          language: artifact.language,
        },
        artifact.content
      );

      const filename =
        /\.[A-Za-z0-9]{1,10}$/.test(stem)
          ? stem
          : `${stem}${ext}`;

      await writeText(
        outputsDir,
        outputUnique(filename),
        artifact.content
      );

      if (artifact.warnings.length) {
        console.warn(
          `Artifact "${artifact.title}" reconstructed with warnings:`,
          artifact.warnings
        );
      }
    }
  }

  // ============================================================
  // Project-level context and files
  // ============================================================

  async function exportProjectContextAndFiles(
    orgId,
    projectId,
    projectRoot,
    filesDir
  ) {
    const base = `${API}/organizations/${orgId}`;

    const [
      project,
      memory,
      docsRaw,
      filesRaw,
    ] = await Promise.all([
      fetchJSON(`${base}/projects/${projectId}`),

      fetchJSON(
        `${base}/memory?project_uuid=${encodeURIComponent(projectId)}`,
        true
      ),

      fetchJSON(
        `${base}/projects/${projectId}/docs`,
        true
      ),

      fetchJSON(
        `${base}/projects/${projectId}/files`,
        true
      ),
    ]);

    const instructions = firstString(
      project?.prompt_template,
      project?.instructions,
      project?.project_instructions
    );

    const description = firstString(
      project?.description,
      project?.summary,
      project?.project_description
    );

    await writeText(
      projectRoot,
      'Project Instructions.md',
      instructions ||
      '(No project instructions were returned by Claude.)\n'
    );

    await writeText(
      projectRoot,
      'Project Memory.md',
      memoryText(memory) ||
      '(No project memory was returned by Claude.)\n'
    );

    await writeText(
      projectRoot,
      'Project Description.md',
      description ||
      '(No project description was returned by Claude.)\n'
    );

    const docs = asArray(docsRaw);
    const files = asArray(filesRaw);

    const unique = makeUniqueNamer();
    const originalsRecovered = new Set();

    for (const f of files) {
      const sourceName =
        f.file_name ||
        f.name ||
        `file-${f.file_uuid || f.uuid || 'unknown'}`;

      const candidates = [
        {
          url: f.download_url,
          label: '',
          original: true,
        },
        {
          url: f.original_url,
          label: '',
          original: true,
        },
        {
          url: f.original_asset?.url,
          label: '',
          original: true,
        },
        {
          url: f.document_asset?.url,
          label: ' [Claude representation]',
          original: false,
        },
        {
          url: f.preview_asset?.url,
          label: ' [Claude preview]',
          original: false,
        },
        {
          url: f.preview_url,
          label: ' [Claude preview]',
          original: false,
        },
        {
          url: f.thumbnail_asset?.url,
          label: ' [Claude thumbnail]',
          original: false,
        },
      ].filter(x => x.url);

      for (const candidate of candidates) {
        try {
          const blob = await fetchBlob(
            absUrl(candidate.url),
            true
          );

          if (!blob) continue;

          let target = sourceName;

          if (candidate.label) {
            const dot = target.lastIndexOf('.');

            target =
              dot > 0
                ? `${target.slice(0, dot)}${candidate.label}${target.slice(dot)}`
                : `${target}${candidate.label}${extensionFromMime(blob.type)}`;
          }

          await writeBlob(
            filesDir,
            unique(target),
            blob
          );

          if (candidate.original) {
            originalsRecovered.add(
              sourceName.toLocaleLowerCase()
            );
          }

          break;
        } catch (e) {
          console.warn(
            `Could not download project file: ${sourceName}`,
            e
          );
        }
      }
    }

    for (const doc of docs) {
      const sourceName =
        doc.file_name ||
        doc.name ||
        `project-doc-${doc.uuid || doc.id || 'unknown'}`;

      if (
        originalsRecovered.has(
          sourceName.toLocaleLowerCase()
        )
      ) {
        continue;
      }

      const content =
        typeof doc.content === 'string'
          ? doc.content
          : JSON.stringify(
              doc.content ?? '',
              null,
              2
            );

      if (!content) continue;

      const textLike =
        /\.(md|markdown|txt|csv|json|html|xml|yaml|yml)$/i
          .test(sourceName);

      const target =
        textLike
          ? sourceName
          : `${sourceName}.extracted.md`;

      await writeText(
        filesDir,
        unique(target),
        content
      );
    }
  }

  // ============================================================
  // Per-chat inputs / attachments / outputs
  // ============================================================

  async function exportChatFiles(
    orgId,
    chatId,
    allMessages,
    activeMessages,
    attachmentsDir,
    outputsDir
  ) {
    const base =
      `${API}/organizations/${orgId}/conversations/${chatId}/wiggle`;

    const attachmentUnique = makeUniqueNamer();
    const outputUnique = makeUniqueNamer();

    const rawUploads = new Set();
    const rawOutputs = new Set();

    try {
      const listing = await fetchJSON(
        `${base}/list-files?prefix=`,
        true
      );

      const metadata =
        asArray(listing?.files_metadata);

      let paths = metadata
        .map(x => x?.path)
        .filter(Boolean);

      if (!paths.length) {
        paths = asArray(
          listing?.files ||
          listing
        );
      }

      for (const path of paths) {
        if (typeof path !== 'string') continue;

        const isUpload =
          path.startsWith(
            '/mnt/user-data/uploads/'
          );

        const isOutput =
          path.startsWith(
            '/mnt/user-data/outputs/'
          );

        if (!isUpload && !isOutput) continue;

        const name =
          path.split('/').pop() ||
          'file';

        try {
          const blob = await fetchBlob(
            `${base}/download-file?path=${encodeURIComponent(path)}`,
            true
          );

          if (!blob) continue;

          if (isUpload) {
            await writeBlob(
              attachmentsDir,
              attachmentUnique(name),
              blob
            );

            rawUploads.add(
              name.toLocaleLowerCase()
            );
          } else {
            await writeBlob(
              outputsDir,
              outputUnique(name),
              blob
            );

            rawOutputs.add(
              name.toLocaleLowerCase()
            );
          }
        } catch (e) {
          console.warn(
            `Could not download workspace file: ${path}`,
            e
          );
        }
      }
    } catch (e) {
      console.warn(
        `Could not list conversation workspace files for ${chatId}`,
        e
      );
    }

    let pasteCounter = 0;

    for (const m of allMessages) {
      for (const obj of [
        ...asArray(m?.attachments),
        ...asArray(m?.files),
      ]) {
        const text =
          typeof obj?.extracted_content === 'string'
            ? obj.extracted_content
            : '';

        if (!text) continue;

        const sourceName =
          obj.file_name ||
          obj.name ||
          `Pasted text ${++pasteCounter}.txt`;

        if (
          rawUploads.has(
            sourceName.toLocaleLowerCase()
          )
        ) {
          continue;
        }

        const saveName =
          /\.[A-Za-z0-9]{1,10}$/.test(sourceName)
            ? sourceName
            : `${sourceName}.txt`;

        await writeText(
          attachmentsDir,
          attachmentUnique(saveName),
          text
        );

        rawUploads.add(
          sourceName.toLocaleLowerCase()
        );
      }
    }

    const recovered =
      new Set(rawUploads);

    for (const m of allMessages) {
      for (const obj of [
        ...asArray(m?.files),
        ...asArray(m?.attachments),
      ]) {
        const sourceName =
          obj?.file_name ||
          obj?.name ||
          '';

        const key =
          sourceName.toLocaleLowerCase();

        if (
          key &&
          recovered.has(key)
        ) {
          continue;
        }

        const candidates = [
          {
            url: obj?.download_url,
            label: '',
          },
          {
            url: obj?.original_url,
            label: '',
          },
          {
            url: obj?.original_asset?.url,
            label: '',
          },
          {
            url: obj?.document_asset?.url,
            label: ' [Claude representation]',
          },
          {
            url: obj?.preview_asset?.url,
            label: ' [Claude preview]',
          },
          {
            url: obj?.preview_url,
            label: ' [Claude preview]',
          },
          {
            url: obj?.thumbnail_asset?.url,
            label: ' [Claude thumbnail]',
          },
          {
            url: obj?.thumbnail_url,
            label: ' [Claude thumbnail]',
          },
        ].filter(x => x.url);

        if (!candidates.length) continue;

        for (const candidate of candidates) {
          try {
            const blob = await fetchBlob(
              absUrl(candidate.url),
              true
            );

            if (!blob) continue;

            let name =
              sourceName ||
              `attachment-${obj?.file_uuid || obj?.id || 'unknown'}`;

            if (candidate.label) {
              const dot =
                name.lastIndexOf('.');

              name =
                dot > 0
                  ? `${name.slice(0, dot)}${candidate.label}${name.slice(dot)}`
                  : `${name}${candidate.label}`;
            }

            if (
              !/\.[A-Za-z0-9]{1,10}$/.test(name)
            ) {
              name +=
                extensionFromMime(blob.type);
            }

            await writeBlob(
              attachmentsDir,
              attachmentUnique(name),
              blob
            );

            if (key) {
              recovered.add(key);
            }

            break;
          } catch (e) {
            console.warn(
              `Could not recover message attachment: ${sourceName || '(unnamed)'}`,
              e
            );
          }
        }
      }
    }

    await saveReconstructedArtifacts(
      activeMessages,
      outputsDir,
      outputUnique
    );

    for (const m of activeMessages) {
      for (const block of asArray(m?.content)) {
        if (
          block?.type !== 'tool_use' ||
          block?.name !== 'create_file' ||
          !block.input
        ) {
          continue;
        }

        const input = block.input;

        const path = firstString(
          input.path,
          input.file_path,
          input.filename,
          input.name
        );

        const content = firstString(
          input.content,
          input.text,
          input.file_content
        );

        if (!path || !content) continue;

        const filename =
          path.split('/').pop() ||
          'generated-file.txt';

        if (
          rawOutputs.has(
            filename.toLocaleLowerCase()
          )
        ) {
          continue;
        }

        await writeText(
          outputsDir,
          outputUnique(filename),
          content
        );

        rawOutputs.add(
          filename.toLocaleLowerCase()
        );
      }
    }
  }

  // ============================================================
  // UI
  // ============================================================

  let statusNode = null;

  function setStatus(text) {
    console.log(
      'Claude exporter:',
      text
    );

    if (statusNode) {
      statusNode.textContent =
        text;
    }
  }

  function buildButton() {
    document
      .getElementById(
        'claude-simple-exporter'
      )
      ?.remove();

    const wrap =
      document.createElement('div');

    wrap.id =
      'claude-simple-exporter';

    Object.assign(
      wrap.style,
      {
        position: 'fixed',
        right: '18px',
        bottom: '18px',
        zIndex: '2147483647',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'flex-end',
        gap: '8px',
        fontFamily:
          'system-ui, sans-serif',
      }
    );

    statusNode =
      document.createElement('div');

    Object.assign(
      statusNode.style,
      {
        display: 'none',
        maxWidth: '460px',
        padding: '8px 10px',
        borderRadius: '8px',
        background:
          'rgba(20,20,20,.92)',
        color: '#fff',
        fontSize: '12px',
      }
    );

    const btn =
      document.createElement('button');

    btn.textContent =
      'Export Claude Project';

    Object.assign(
      btn.style,
      {
        padding: '10px 14px',
        borderRadius: '10px',
        cursor: 'pointer',
        border:
          '1px solid rgba(127,127,127,.35)',
        background: '#f0eee6',
        color: '#222',
        fontWeight: '650',
      }
    );

    wrap.append(
      statusNode,
      btn
    );

    document.body.appendChild(
      wrap
    );

    return btn;
  }

  // ============================================================
  // Run
  // ============================================================

  const projects =
    await discoverProjects();

  const btn =
    buildButton();

  console.log(
    `Claude exporter ready. Found ${projects.length} project(s).`
  );

  btn.addEventListener(
    'click',
    async () => {
      try {
        const selected =
          chooseProject(projects);

        if (!selected) return;

        if (
          !window.showDirectoryPicker
        ) {
          throw new Error(
            'Use Chrome or Edge: this browser cannot choose an export folder.'
          );
        }

        const destination =
          await window.showDirectoryPicker({
            mode: 'readwrite',
          });

        btn.disabled = true;
        statusNode.style.display =
          'block';

        const orgId =
          selected.org.uuid;

        const projectId =
          selected.project.uuid;

        const projectName =
          selected.project.name ||
          'Untitled Claude Project';

        const projectRoot =
          await getDir(
            destination,
            projectName
          );

        const filesDir =
          await getDir(
            projectRoot,
            'Files'
          );

        const chatsRoot =
          await getDir(
            projectRoot,
            'Chats'
          );

        setStatus(
          'Exporting project instructions, memory, description and files…'
        );

        await exportProjectContextAndFiles(
          orgId,
          projectId,
          projectRoot,
          filesDir
        );

        const conversations =
          asArray(
            await fetchJSON(
              `${API}/organizations/${orgId}/projects/${projectId}/conversations`
            )
          );

        const uniqueChatFolder =
          makeUniqueNamer();

        for (
          let i = 0;
          i < conversations.length;
          i++
        ) {
          const c =
            conversations[i];

          const chatId =
            c.uuid ||
            c.id;

          const title =
            c.name ||
            c.title ||
            'Untitled chat';

          setStatus(
            `Exporting ${i + 1}/${conversations.length}: ${title}`
          );

          const raw =
            await fetchJSON(
              `${API}/organizations/${orgId}/chat_conversations/${chatId}` +
              `?tree=True&rendering_mode=messages&render_all_tools=true&consistency=eventual`
            );

          const allMessages =
            asArray(
              raw.chat_messages
            );

          const activeMessages =
            activeBranch(
              allMessages,
              raw.current_leaf_message_uuid
            );

          const chatFolderName =
            uniqueChatFolder(title);

          const chatDir =
            await getDir(
              chatsRoot,
              chatFolderName
            );

          const attachmentsDir =
            await getDir(
              chatDir,
              'Attachments'
            );

          const outputsDir =
            await getDir(
              chatDir,
              'Outputs'
            );

          await writeText(
            chatDir,
            `${safeName(title)}.md`,
            renderChatMarkdown(
              { ...c, ...raw },
              activeMessages,
              projectName
            )
          );

          await exportChatFiles(
            orgId,
            chatId,
            allMessages,
            activeMessages,
            attachmentsDir,
            outputsDir
          );

          await sleep(100);
        }

        setStatus(
          `Done — ${conversations.length} chats exported.`
        );

        btn.textContent =
          'Export complete';
      } catch (e) {
        console.error(
          'Claude exporter failed:',
          e
        );

        statusNode.style.display =
          'block';

        statusNode.textContent =
          `Export failed: ${e.message || e}`;

        btn.disabled = false;
      }
    }
  );
})();