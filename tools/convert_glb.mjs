// 把 Babylon.js 管线导出的 GLB 转成 Godot 4 可导入的 glTF
//
// 为什么需要这一步：
//   原版 GTA_SZ 的 219 个 GLB 中有 168 个使用 EXT_meshopt_compression +
//   KHR_mesh_quantization，且都写在 extensionsRequired 里。Godot 4 不支持这两个
//   扩展，会**直接拒绝导入**（表现为 `.import` 里 valid=false、模型静默回退成占位盒）。
//   另有 2 个文件把 KHR_texture_transform 写在 extensionsRequired 里。
//
// 本脚本做四件事：
//   1. 注册 meshopt 解码器，读出被压缩的几何
//   2. 卸载 EXT_meshopt_compression 与 KHR_mesh_quantization
//   3. 把 normalized 整型 accessor 还原成 FLOAT（Accessor 没有 setComponentType，
//      组件类型由 setArray 传入的 TypedArray 自动推断）
//   4. 把 KHR_texture_transform 烘焙进 UV 后卸载该扩展
//
// 用法（需先 `npm i @gltf-transform/core @gltf-transform/extensions meshoptimizer`）：
//   node convert_glb.mjs <srcPublicDir> <dstDataDir>
//
// 注意：临时文件名必须保留 .glb 后缀，否则 NodeIO.write() 会按扩展名选错写出器，
//      输出一个几 KB 的 .gltf JSON 加 sidecar .bin，看起来像"模型被清空了"。

import { NodeIO } from '@gltf-transform/core';
import {
  ALL_EXTENSIONS,
  EXTMeshoptCompression,
  KHRMeshQuantization,
  KHRTextureTransform,
} from '@gltf-transform/extensions';
import { MeshoptDecoder } from 'meshoptimizer';
import fs from 'node:fs';
import path from 'node:path';

const SRC = process.argv[2];
const DST = process.argv[3];
if (!SRC || !DST) {
  console.error('usage: node convert_glb.mjs <srcPublicDir> <dstDataDir>');
  process.exit(2);
}

const GLB_HEADER = 12;
const CHUNK_HEADER = 8;

function readExtensions(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.alloc(GLB_HEADER);
    if (fs.readSync(fd, head, 0, GLB_HEADER, 0) < GLB_HEADER) return null;
    if (head.toString('utf8', 0, 4) !== 'glTF') return null;
    const chunk = Buffer.alloc(CHUNK_HEADER);
    fs.readSync(fd, chunk, 0, CHUNK_HEADER, GLB_HEADER);
    const len = chunk.readUInt32LE(0);
    const json = Buffer.alloc(len);
    fs.readSync(fd, json, 0, len, GLB_HEADER + CHUNK_HEADER);
    const d = JSON.parse(json.toString('utf8'));
    return {
      used: d.extensionsUsed || [],
      required: d.extensionsRequired || [],
    };
  } finally {
    fs.closeSync(fd);
  }
}

const DENORM = {
  5120: (v) => Math.max(v / 127, -1), // BYTE
  5121: (v) => v / 255, // UNSIGNED_BYTE
  5122: (v) => Math.max(v / 32767, -1), // SHORT
  5123: (v) => v / 65535, // UNSIGNED_SHORT
  5125: (v) => v / 4294967295, // UNSIGNED_INT
};

/** 把 material 上所有 texture slot 的 KHR_texture_transform 烘焙进该材质所用图元的 UV。 */
function bakeTextureTransforms(doc) {
  let baked = 0;
  for (const material of doc.getRoot().listMaterials()) {
    const slots = [
      material.getBaseColorTextureInfo?.(),
      material.getMetallicRoughnessTextureInfo?.(),
      material.getNormalTextureInfo?.(),
      material.getOcclusionTextureInfo?.(),
      material.getEmissiveTextureInfo?.(),
    ].filter(Boolean);

    for (const info of slots) {
      const ext = info.getExtension('KHR_texture_transform');
      if (!ext) continue;
      let offset, rotation, scale, texCoord;
      try {
        [offset, rotation, scale] = ext.getTransform();
        texCoord = ext.getTexCoord();
      } catch {
        continue;
      }
      if (!offset && !scale) continue;
      const o = offset || [0, 0];
      const s = scale || [1, 1];
      const r = rotation || 0;
      const cos = Math.cos(r);
      const sin = Math.sin(r);

      for (const mesh of doc.getRoot().listMeshes()) {
        for (const prim of mesh.listPrimitives()) {
          if (prim.getMaterial() !== material) continue;
          const uv = prim.getAttribute(`TEXCOORD_${texCoord || 0}`);
          if (!uv) continue;
          let arr;
          try {
            arr = uv.getArray();
          } catch {
            continue; // interleaved accessor 无法逐元素改写
          }
          if (!arr) continue;
          const out = new Float32Array(arr.length);
          for (let i = 0; i < arr.length; i += 2) {
            const u = arr[i];
            const v = arr[i + 1];
            out[i] = (u * cos - v * sin) * s[0] + o[0];
            out[i + 1] = (u * sin + v * cos) * s[1] + o[1];
          }
          uv.setNormalized(false).setArray(out);
          baked++;
        }
      }
      // 归零，便于随后整体卸载扩展
      try {
        ext.setTransform([0, 0], 0, [1, 1]);
      } catch {
        /* ignore */
      }
    }
  }
  return baked;
}

function dequantize(doc) {
  let n = 0;
  for (const acc of doc.getRoot().listAccessors()) {
    const ct = acc.getComponentType();
    if (ct === 5126 || !acc.getNormalized() || !DENORM[ct]) continue;
    let src;
    try {
      src = acc.getArray();
    } catch {
      continue; // interleaved
    }
    if (!src) continue;
    const dst = new Float32Array(src.length);
    const f = DENORM[ct];
    for (let i = 0; i < src.length; i++) dst[i] = f(src[i]);
    acc.setNormalized(false).setArray(dst);
    n++;
  }
  return n;
}

const io = new NodeIO()
  .registerExtensions(ALL_EXTENSIONS)
  .registerDependencies({ 'meshopt.decoder': MeshoptDecoder });

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const files = walk(SRC);
const report = { total: 0, converted: 0, copied: 0, skipped: [], failed: [], bytesIn: 0, bytesOut: 0 };

for (const file of files) {
  const rel = path.relative(SRC, file);
  const out = path.join(DST, rel);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const sizeIn = fs.statSync(file).size;
  report.total++;
  report.bytesIn += sizeIn;

  const ext = path.extname(file).toLowerCase();
  const exts = ext === '.glb' ? readExtensions(file) : null;
  const blocking =
    exts &&
    (exts.required.includes('EXT_meshopt_compression') ||
      exts.required.includes('KHR_mesh_quantization') ||
      exts.required.includes('KHR_texture_transform'));

  if (!blocking) {
    fs.copyFileSync(file, out);
    report.copied++;
    report.bytesOut += fs.statSync(out).size;
    continue;
  }

  try {
    const doc = await io.read(file);
    const bakedUv = bakeTextureTransforms(doc);
    const deq = dequantize(doc);

    for (const e of [...doc.getRoot().listExtensionsUsed()]) {
      if (e.extensionName === 'EXT_meshopt_compression' || e.extensionName === 'KHR_mesh_quantization') {
        e.dispose();
      }
    }
    // 显式创建再 dispose，确保扩展从 extensionsUsed/Required 中彻底移除
    doc.createExtension(EXTMeshoptCompression).dispose();
    doc.createExtension(KHRMeshQuantization).dispose();
    for (const e of [...doc.getRoot().listExtensionsUsed()]) {
      if (e.extensionName === 'KHR_texture_transform') e.dispose();
    }
    try {
      doc.createExtension(KHRTextureTransform).dispose();
    } catch {
      /* ignore */
    }

    const tmp = out + '.tmp.glb'; // 必须保留 .glb 后缀
    await io.write(tmp, doc);
    fs.renameSync(tmp, out);
    report.converted++;
    report.bytesOut += fs.statSync(out).size;
    process.stdout.write(
      `  [conv] ${rel}  ${(sizeIn / 1048576).toFixed(1)}MB -> ${(fs.statSync(out).size / 1048576).toFixed(1)}MB` +
        `  uv=${bakedUv} deq=${deq}\n`,
    );
  } catch (err) {
    report.failed.push({ rel, error: String(err && err.message ? err.message : err) });
    try {
      fs.copyFileSync(file, out);
    } catch {
      /* ignore */
    }
    process.stdout.write(`  [FAIL] ${rel}: ${err}\n`);
  }
}

console.log('\n=== 转换报告 ===');
console.log(JSON.stringify({
  total: report.total,
  converted: report.converted,
  copied: report.copied,
  failed: report.failed.length,
  bytesInMB: +(report.bytesIn / 1048576).toFixed(1),
  bytesOutMB: +(report.bytesOut / 1048576).toFixed(1),
}, null, 2));
if (report.failed.length) {
  console.log('失败清单：');
  for (const f of report.failed) console.log('  ' + f.rel + ' :: ' + f.error);
}
