/**
 * 扫描目录下所有 PDF，提取正文文本并匹配客户名。
 * 用法: node scanpdf.js "<目录>"   （目录路径本身不要带空格）
 *
 * 为什么在 Node 里遍历而不是由 PowerShell 传文件名：
 * 文件名常含空格，经命令行传递会被截断。目录路径无空格，故只传目录。
 *
 * 用 pdf-parse/lib/pdf-parse.js 而非主入口：
 * 主入口在判断调用来源失败时会进入 debug 模式，读取自带测试 PDF，
 * 导致所有文件返回同一段文本。
 */
const fs = require('fs');
const path = require('path');

// 依赖 node_modules 有 66MB/1176 个文件，不适合搬到桌面，
// 因此脚本可放桌面、依赖留原目录：先找同目录，找不到再回退到配置中的路径。
function loadParser() {
    try {
        return require('pdf-parse/lib/pdf-parse.js');
    }
    catch (e) {
        const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8'));
        const base = cfg.nodeModulesPath || 'D:\\project\\desktop-organizer\\node_modules';
        return require(path.join(base, 'pdf-parse', 'lib', 'pdf-parse.js'));
    }
}
const pdf = loadParser();

const dir = process.argv[2];
if (!dir) { console.error('用法: node scanpdf.js <目录>'); process.exit(1); }

const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8'));
const clients = cfg.clients;

const files = fs.readdirSync(dir).filter((f) => /\.pdf$/i.test(f));

// 抓 Borrower / Applicant 附近的文本，便于人工核对归属
function nameContext(text) {
    const m = text.match(/(borrower|applicant|loan applicant)[\s\S]{0,70}/i);
    return m ? m[0].replace(/\s+/g, ' ').trim() : null;
}

(async () => {
    const results = [];
    for (const f of files) {
        const full = path.join(dir, f);
        let text = '';
        try {
            const data = await pdf(fs.readFileSync(full));
            text = (data.text || '').replace(/\s+/g, ' ').trim();
        }
        catch (e) {
            text = '';   // 扫描件或无文本层：以空文本表示，交给调用方兜底
        }

        // 只保留后置词边界，前置刻意不加，原因有二：
        // 1) 排除误命中："Tran" 不会命中 "Transaction"（后面紧跟 s，非边界）
        // 2) 保留真命中：PDF 文本常把标签与值粘连成 "BorrowerAlice Sun"、
        //    "APPLICANTSChun Zhang"，若要求前置边界，真正的客户也会被挡掉
        const hits = [];
        for (const c of clients) {
            const escaped = c.key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            const m = text.match(new RegExp(escaped + '\\b', 'i'));
            if (m) hits.push({ key: c.key, pos: m.index });
        }
        // 最早出现的通常是主借款人（Borrower 字段排在 Co-Borrower 之前）
        hits.sort((a, b) => a.pos - b.pos);

        results.push({
            file: f,
            chars: text.length,
            hits: hits.map((h) => h.key),
            best: hits.length ? hits[0].key : null,
            context: nameContext(text),
        });
    }
    console.log(JSON.stringify(results));
})();
