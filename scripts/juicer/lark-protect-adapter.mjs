// A freshly deployed adapter needs the same duster protection as other custody.
import {context,live} from './lark-context.mjs';
const c=await context();
try{
 const who=await c.nativeAccount(c.r.market.swapper);
 if((await c.api.query.duster.accountWhitelist(who)).isNone)await c.enact('protect-adapter-custody',[c.api.tx.duster.whitelistAccount(who)]);
 if(live){c.r.checks.adapterWhitelisted=(await c.api.query.duster.accountWhitelist(who)).isSome;c.save();console.log('ADAPTER WHITELISTED',c.r.checks.adapterWhitelisted);}
}finally{await c.api.disconnect();}
