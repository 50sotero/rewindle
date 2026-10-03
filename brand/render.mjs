// Rasterize the canonical SVGs. Run with SHARP_MODULE pointing at an installed
// sharp module, or install sharp in a local development environment.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const sharp = require(process.env.SHARP_MODULE || 'sharp');
const root = path.dirname(fileURLToPath(import.meta.url));
const vector = await fs.readFile(path.join(root, 'app-icon.svg'));
const sizes = [16,24,32,48,64,128,256,512,1024];
const images = new Map();
for (const size of sizes) images.set(size, await sharp(vector, {density: 1536}).resize(size,size).png().toBuffer());
await fs.writeFile(path.join(root,'app-icon.png'),images.get(1024));
await sharp(path.join(root,'social-card.svg')).png().toFile(path.join(root,'social-card.png'));
const icoSizes = sizes.filter(size=>size<=256), header = Buffer.alloc(6+16*icoSizes.length);
header.writeUInt16LE(1,2); header.writeUInt16LE(icoSizes.length,4);
let offset=header.length;
for (const [index,size] of icoSizes.entries()) {
  const data=images.get(size), at=6+16*index;
  header[at]=size===256?0:size;header[at+1]=size===256?0:size;
  header.writeUInt16LE(1,at+4);header.writeUInt16LE(32,at+6);
  header.writeUInt32LE(data.length,at+8);header.writeUInt32LE(offset,at+12);offset+=data.length;
}
await fs.writeFile(path.join(root,'app-icon.ico'),Buffer.concat([header,...icoSizes.map(size=>images.get(size))]));
const chunks=[];
for(const [type,size] of [['icp4',16],['icp5',32],['icp6',64],['ic07',128],['ic08',256],['ic09',512],['ic10',1024]]){
 const png=images.get(size),h=Buffer.alloc(8);h.write(type);h.writeUInt32BE(png.length+8,4);chunks.push(h,png);
}
const icns=Buffer.alloc(8);icns.write('icns');icns.writeUInt32BE(8+chunks.reduce((n,c)=>n+c.length,0),4);
await fs.writeFile(path.join(root,'app-icon.icns'),Buffer.concat([icns,...chunks]));
console.log('Rendered PNG, Windows ICO (7 sizes), macOS ICNS, and social card');
