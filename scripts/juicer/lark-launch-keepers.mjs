// Lark only, after the launch referendum: it gave the loop's KEEPER_ROLE and each vault's DEPOSIT_GUARDIAN_ROLE to
// the mainnet keepers, whose keys a lark lacks. One referendum gives the same roles to the lark's test keepers (test
// accounts 18 and 20, the stack's keeper0 and keeper1); the mainnet keepers keep theirs.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {context,v,testAccount,role,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
assert.ok(profile.launch,`${profile.name} is not a launch-process profile`);
const LABEL='lark-test-keeper-roles';
const abi=v.parseAbi(['function grantRole(bytes32,address)','function hasRole(bytes32,address) view returns (bool)']);
const c=await context();
try{
 const {r,pub,save,govEvm,enact}=c;
 assert.ok(r.launchReferendum?.clean&&r.launch?.plan,'the launch referendum has not enacted clean, or its plan is not adopted');
 const mainnet=JSON.parse(readFileSync(r.launch.plan,'utf8')).keepers,keepers=[18,20].map(i=>testAccount(i).address);
 const roles=[[r.addresses.source,'KEEPER_ROLE'],...r.vaults.map(x=>[x.address,'DEPOSIT_GUARDIAN_ROLE'])];
 const has=(address,name,who)=>pub.readContract({address,abi,functionName:'hasRole',args:[role(name),who]});
 const missing=async who=>{const out=[];for(const [address,name] of roles)if(!await has(address,name,who))out.push([address,name]);return out;};
 for(const k of mainnet)assert.deepEqual(await missing(k),[],`mainnet keeper ${k} lacks a launch role`);
 Object.assign(r.testSigners,{keeper:keepers[0],keeperSecondary:keepers[1]});
 r.larkKeepers={keepers,mainnet,roles:roles.map(([address,name])=>({address,role:name}))};save();
 const grants=[];
 for(const k of keepers)for(const [address,name] of await missing(k))grants.push(govEvm(address,abi,'grantRole',[role(name),k],500000));
 if(grants.length||r.governance.some(g=>g.label===LABEL))await enact(LABEL,grants);
 if(live){
  for(const k of [...keepers,...mainnet])assert.deepEqual(await missing(k),[],`${k} lacks a keeper role`);
  r.checks.larkKeepers=true;save();
  console.log('LARK KEEPERS',JSON.stringify(r.larkKeepers));
 }
}finally{await c.api.disconnect();}
