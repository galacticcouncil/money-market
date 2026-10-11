// A single-depositor economic model, NOT a Solidity/keeper transaction replay.
// Pool-143 fills use official integer SDK math. No gas is charged to users.
import assert from 'node:assert/strict';
import {poolQuote} from './pressure-model.mjs';

const DAY = 86400;
const native = (n, decimals) => BigInt(Math.floor(n * 10 ** decimals));
const human = (n, decimals) => Number(n) / 10 ** decimals;
const copy = p => structuredClone(p);
export function asPool(point) {
  return {info:{fee:point.feePermill,finalAmplification:point.amplification},
    reserves:[43,222].map((id,i)=>({id,balance:point.reserves[i],info:{decimals:i?18:6}})),
    pegs:{current:point.pegs.map(v=>[v.num,v.den])}};
}
function fill(stable, pool, buy, amount) {
  const raw = native(amount,buy?18:6);
  if (raw <= 0n || pool.reserves.some(r=>BigInt(r.balance)<=0n)) return null;
  const out = poolQuote(stable,pool,buy?222:43,buy?43:222,raw);
  if (out <= 0n) return null;
  return {raw,out,input:human(raw,buy?18:6),output:human(out,buy?6:18)};
}
function apply(pool,buy,q) {
  const i = buy?1:0, o=1-i;
  pool.reserves[i].balance = (BigInt(pool.reserves[i].balance)+q.raw).toString();
  pool.reserves[o].balance = (BigInt(pool.reserves[o].balance)-q.out).toString();
}

// Ideal arb restores the infinitesimal price to the external oracle BEFORE
// every strategy trade. It preserves fees and the trade's own price impact.
// Bisection uses fee-free quotes solely to locate the fair marginal price;
// the outside trade that reaches that state still pays the actual pool fee.
export function equilibrate(stable, original, nav) {
  const marginal = p => {
    const p0=copy(p); p0.info.fee=0;
    return fill(stable,p0,true,1)?.output * nav;
  };
  const first = marginal(original);
  assert.ok(first>0 && Number.isFinite(first));
  const buy = first>1;
  let lo=0, hi=human(BigInt(original.reserves[buy?1:0].balance),buy?18:6)*4;
  for(let k=0;k<48;k++) {
    const mid=(lo+hi)/2,p=copy(original),q=fill(stable,p,buy,mid);
    if(!q) {hi=mid;continue;}
    apply(p,buy,q);
    const ratio=marginal(p);
    if(buy ? ratio>1 : ratio<1) lo=mid; else hi=mid;
  }
  const p=copy(original),q=fill(stable,p,buy,(lo+hi)/2);
  if(q) apply(p,buy,q);
  assert.ok(Math.abs(marginal(p)-1)<0.00002,'ideal arb failed to converge');
  return p;
}

export class PoolReplay {
  constructor(stable,mode='observed') {
    this.stable=stable;this.mode=mode;this.delta=[0n,0n];this.base=null;
    this.trades=0;this.poolFees=0;this.quoteLoss=0;
  }
  observe(point,nav,ideal) {
    if(!this.first)this.first=asPool(point);
    this.nav=nav;this.point=point;
    this.base=this.mode==='perfect'?copy(ideal):asPool(point);
    if(this.mode==='none')this.base.reserves=copy(this.first.reserves);
  }
  state() {
    const p=copy(this.base);
    if(this.mode!=='perfect')for(let i=0;i<2;i++)p.reserves[i].balance=(BigInt(p.reserves[i].balance)+this.delta[i]).toString();
    return p;
  }
  quote(buy,amount) {return fill(this.stable,this.state(),buy,amount);}
  execute(buy,q) {
    const p=this.state(),before=p.reserves.map(r=>BigInt(r.balance));
    const zero=copy(p);zero.info.fee=0;
    const gross=fill(this.stable,zero,buy,q.input);
    this.poolFees += (gross.output-q.output)*(buy?this.nav:1);
    this.quoteLoss += buy?q.input-q.output*this.nav:q.input*this.nav-q.output;
    apply(p,buy,q);
    if(this.mode!=='perfect')for(let i=0;i<2;i++)this.delta[i]+=BigInt(p.reserves[i].balance)-before[i];
    ++this.trades;
  }
}

export function prepare(history,math) {
  const markets=new Map(history.markets.map(m=>[m.block,m]));
  const points=history.snapshots.flatMap(s=>s.points).filter(p=>p.t>=history.start&&p.t<history.end);
  return points.map(p=> {
    const m=markets.get(p.block);assert.ok(m,`missing exact oracle/index block ${p.block}`);
    assert.equal(m.substrateHash,p.hash);assert.equal(m.t,p.t);
    assert.equal(Number(m.prices[3]),1e8,'model assumes dollar HOLLAR');
    const row={...p,prices:m.prices.map(x=>Number(x)/1e8),income:Number(m.incomeIndex)/1e27,debt:Number(m.debtIndex)/1e27};
    row.ideal=equilibrate(math.stable,asPool(p),row.prices[2]);
    return row;
  });
}

export const BASE_POLICY=Object.freeze({size:8000,daily:5000,burst:8000,
  sourceLimitBps:8,sourceReserveBps:10,thresholdBps:30,minHarvest:1,maxHarvest:200,
  harvestDaily:1000,harvestEveryHours:0,entryEveryHours:0,adaptive:false,feeBps:500,
  cryptoLimitBps:100,tailBps:null,serviceBps:null});

export function selectPolicy(candidates,incumbent) {
  const ranked=[...candidates].sort((a,b)=>b.score-a.score||
    (a.policy.sourceLimitBps??8)-(b.policy.sourceLimitBps??8)||
    (a.policy.size??8000)-(b.policy.size??8000));
  const improved=ranked.find(x=>x.score>incumbent.score+1e-8&&x.meanFundedPct>incumbent.meanFundedPct+1e-8);
  return {winner:improved??incumbent,identifiedImprovement:!!improved,bestDiagnostic:ranked[0]};
}

export function simulate(rows,math,asset,policy={},mode='observed',tvl=10000) {
  assert.ok(rows.length>1);
  const c={...BASE_POLICY,...policy}, ai=asset==='ETH'?0:1, ltv=ai?0.8:0.75;
  const tail=(c.tailBps??(ai?96:56))/10000,service=(c.serviceBps??(ai?100:60))/10000,fee=c.feeBps/10000;
  assert.ok(c.sourceReserveBps>=c.sourceLimitBps && fee<1 && tail<1 && service<1);
  const start=rows[0],initial=tvl/start.prices[ai],pool=new PoolReplay(math.stable,mode);
  const s={crypto:0,wallet:initial,prime:0,main:0,principal:0,loop:0,cash:0,fees:0,credit:0};
  const m={income:0,interest:0,cryptoMark:0,tailLoss:0,serviceLoss:0,entryVolume:0,
    harvestVolume:0,entryTrades:0,harvests:0,repays:0,quoteSkips:0,readySkips:0,
    firstDeposit:null,firstCrypto:null,minSourceHf:null,maxBackingDeficit:0,
    blockedHours:0,budgetBlockedHours:0,pendingCarryDollarHours:0,liquidatable:false,
    maxAccountingError:0,history:[]};
  let previous=start,budget=c.burst,harvestBudget=c.maxHarvest,lastHarvest=-Infinity,lastEntry=-Infinity;
  let unwindTarget=null,price=start.prices[ai],nav=start.prices[2],gross=()=>s.prime*nav;
  const equity=()=>gross()+s.cash-s.loop;
  const interest=()=>Math.max(0,s.main-s.principal);
  const required=()=>s.main+interest()*fee/(1-fee);
  const ready=()=>equity()+1e-7>=required();
  const carry=()=>Math.max(0,equity()-required())*(1-fee);
  const repayMain=amount=> {
    const paid=Math.min(amount,s.main),principalPaid=Math.max(0,paid-interest());
    s.main-=paid;s.principal-=Math.min(s.principal,principalPaid);return paid;
  };
  function choose(buy,amount,minUsd,ceiling,tailCost=0) {
    let size=amount;
    for(let i=0;i<(c.adaptive?12:1)&&size*(buy?1:nav)>=minUsd;i++,size/=2) {
      const q=pool.quote(buy,size);if(!q)continue;
      const value=q.input*(buy?1:nav),out=q.output*(buy?nav:1)*(1-tailCost);
      if((1-out/value)*10000<=ceiling+1e-6)return q;
    }
    ++m.quoteSkips;return null;
  }
  function enter(amount,main,deposit,t) {
    amount=Math.min(amount,c.size,budget);
    if(amount<10)return false;
    const q=choose(true,amount,10,c.sourceLimitBps);if(!q)return false;
    pool.execute(true,q);s.prime+=q.output;budget-=q.input;
    if(main){s.main+=q.input;s.principal+=q.input;}else s.loop+=q.input;
    if(deposit){const units=q.input/price/ltv;s.crypto+=units;s.wallet-=units;}
    m.entryVolume+=q.input;m.entryTrades++;
    if(m.firstDeposit===null)m.firstDeposit=(t-start.t)/DAY;
    return true;
  }
  for(const row of rows) {
    const dt=row.t-previous.t;assert.ok(dt>=0);
    const oldCrypto=s.crypto+s.wallet-initial,oldFees=s.fees,oldGross=s.prime*nav;
    s.prime*=row.income/previous.income;
    m.income+=s.prime*row.prices[2]-oldGross;
    const debtRatio=row.debt/previous.debt;
    assert.ok(debtRatio>=1-1e-12,'debt index decreased');
    m.interest+=(s.main+s.loop)*(debtRatio-1);s.main*=debtRatio;s.loop*=debtRatio;
    m.cryptoMark+=(oldCrypto+oldFees)*(row.prices[ai]-price);
    price=row.prices[ai];nav=row.prices[2];
    budget=Math.min(c.burst,budget+c.daily*dt/DAY);
    harvestBudget=Math.min(c.maxHarvest,harvestBudget+c.harvestDaily*dt/DAY);
    pool.observe(row,nav,row.ideal);
    const hf=s.loop?gross()*.88/s.loop:Infinity;
    if(Number.isFinite(hf))m.minSourceHf=Math.min(m.minSourceHf??Infinity,hf);
    if(hf<1)m.liquidatable=true;
    if(!ready()){m.blockedHours+=dt/3600;m.readySkips++;}
    m.maxBackingDeficit=Math.max(m.maxBackingDeficit,s.main-equity());
    if(budget<10)m.budgetBlockedHours+=dt/3600;
    m.pendingCarryDollarHours+=carry()*dt/3600;
    // Main has a synthetic HF floor. Rebalance reduces its desired exposure;
    // source HF is still a real safety constraint. No prior crypto pays debt.
    if(s.crypto && s.main>s.crypto*price*(ltv+.03) && unwindTarget===null)
      unwindTarget=s.crypto*price*ltv;
    for(let k=0;k<8 && !m.liquidatable;k++) {
      const safety=s.loop && gross()*.88/s.loop<1.05;
      if(!safety && unwindTarget===null)break;
      const safe=Math.max(0,(gross()-s.loop*1.02/.88)*.9);
      const need=safety?(1.05*s.loop-.88*gross())/(1.05-.88):
        Math.max(0,s.main-unwindTarget)/(1-s.loop/gross());
      const amount=Math.min(c.size,safe,need*(1+c.sourceReserveBps/10000))/nav;
      const q=choose(false,amount,.01,c.sourceLimitBps);if(!q)break;
      const beforeGross=gross(),debt=s.loop;pool.execute(false,q);s.prime-=q.input;
      const sourceRepay=Math.min(s.loop,safety?q.output:q.output*debt/(beforeGross-q.input*nav+q.output));
      s.loop-=sourceRepay;const cash=q.output-sourceRepay;
      if(safety)s.cash+=cash;else s.cash+=cash-repayMain(Math.min(cash,Math.max(0,s.main-unwindTarget)));
      ++m.repays;
      if(unwindTarget!==null&&s.main<=unwindTarget+.01)unwindTarget=null;
      if(s.prime<1e-7)break;
    }
    // Harvests withdraw only surplus over principal and the execution reserve,
    // and retain source HF >=1.05. Service Main interest out of fresh crypto.
    const available=Math.min(Math.max(0,equity()-s.principal-gross()*c.sourceReserveBps/10000),
      Math.max(0,gross()-s.loop*1.05/.88));
    if(!m.liquidatable && available>=Math.max(c.minHarvest,s.principal*c.thresholdBps/10000)
      && row.t-lastHarvest>=c.harvestEveryHours*3600) {
      const amount=Math.min(available,harvestBudget)/nav;
      const q=choose(false,amount,c.minHarvest,c.cryptoLimitBps,tail);
      if(q) {
        pool.execute(false,q);s.prime-=q.input;
        const received=q.output*(1-tail);m.tailLoss+=q.output*tail;
        const coins=received/price,feeCoins=coins*fee;s.fees+=feeCoins;
        const usable=coins-feeCoins,serviceCoins=Math.min(usable,Math.max(0,interest()-s.cash)/(price*(1-service)));
        const cash=serviceCoins*price*(1-service);m.serviceLoss+=serviceCoins*price*service;
        s.cash+=cash;s.cash-=repayMain(Math.min(s.cash,interest()));
        s.crypto+=usable-serviceCoins;
        s.credit+=usable-serviceCoins;
        ++m.harvests;m.harvestVolume+=q.input*nav;harvestBudget-=q.input*nav;lastHarvest=row.t;
        if(m.firstCrypto===null && s.crypto+s.wallet>initial+1e-12)m.firstCrypto=(row.t-start.t)/DAY;
      }
    }
    if(!m.liquidatable && unwindTarget===null && row.t-lastEntry>=c.entryEveryHours*3600) {
      const tradesBefore=m.entryTrades;
      for(let k=0;k<8&&s.wallet*price>=20&&ready();k++)
        if(!enter(s.wallet*price*ltv,true,true,row.t))break;
      if(s.crypto&&ready()) {
        const full=Math.max(0,s.crypto*price*ltv-s.main);
        // CompoundLogic.rebalance: freshly earned collateral bypasses the
        // 5pp price hysteresis, up to its own unused borrowing capacity.
        const need=s.main<s.crypto*price*(ltv-.05)?full:Math.min(full,s.credit*price*ltv);
        const before=s.main;
        if(need>=10&&enter(need,true,false,row.t))s.credit*=Math.max(0,1-(s.main-before)/need);
      }
      for(let k=0;k<8&&ready()&&equity()>=s.principal&&!m.liquidatable;k++) {
        if(s.loop&&gross()*.88/s.loop<=1.05*1.005)break;
        const earned=Math.max(0,equity()-s.principal),capacity=(gross()-earned)*.88/1.05-s.loop;
        if(!enter(capacity,false,false,row.t))break;
      }
      if(m.entryTrades>tradesBefore)lastEntry=row.t;
    }
    assert.ok(s.crypto+s.wallet>=initial-1e-10,'funded principal crypto was spent');
    assert.ok(s.prime>=-1e-6&&s.loop>=-1e-7&&s.main>=-1e-7&&s.cash>=-1e-7&&s.wallet>=-1e-10);
    const funded=(s.crypto+s.wallet-initial)*price;
    const wealth=funded+s.fees*price+equity()-s.main;
    const expected=m.income-m.interest+m.cryptoMark-pool.quoteLoss-m.tailLoss-m.serviceLoss;
    m.maxAccountingError=Math.max(m.maxAccountingError,Math.abs(wealth-expected));
    assert.ok(Math.abs(wealth-expected)<.00001,`unreconciled wealth ${wealth-expected}`);
    if(row===rows.at(-1)||Math.floor(row.t/DAY)!==Math.floor(previous.t/DAY))
      m.history.push({t:row.t,price,cryptoReturnPct:100*(s.crypto+s.wallet-initial)/initial,
        carry:carry(),backingDeficit:Math.max(0,s.main-equity()),sourceGross:gross(),sourceHf:s.loop?gross()*.88/s.loop:null});
    previous=row;
  }
  const days=(previous.t-start.t)/DAY,fundedUnits=Math.max(0,s.crypto+s.wallet-initial),ret=fundedUnits/initial;
  return {asset,mode,policy:c,tvl,from:new Date(start.t*1000).toISOString(),to:new Date(previous.t*1000).toISOString(),days,
    priceReturnPct:100*(price/start.prices[ai]-1),fundedCryptoReturnPct:ret*100,
    annualizedFundedCryptoPct:100*((1+ret)**(365/days)-1),fundedCryptoUnits:fundedUnits,
    fundedCryptoUsd:fundedUnits*price,unconvertedUserUsd:carry(),backingDeficitUsd:Math.max(0,s.main-equity()),
    unadmittedInitialPct:100*Math.max(0,s.wallet)/initial,sourceGrossUsd:gross(),sourceEquityUsd:equity(),
    mainDebtUsd:s.main,loopDebtUsd:s.loop,protocolFeesUsd:s.fees*price,
    poolFeeUsd:pool.poolFees,sourceQuoteLossUsd:pool.quoteLoss,
    totalTradingLossUsd:pool.quoteLoss+m.tailLoss+m.serviceLoss,
    quoteDislocationAndImpactUsd:pool.quoteLoss-pool.poolFees,
    // Main debt and retained strategy assets are separate from funded crypto.
    // Carry is never silently included in the funded-return score.
    ...m};
}

export function regimeWindows(history,trainingEnd,days=14) {
  const daySeconds=days*DAY,prices={};
  for(const asset of ['ETH','BTC']) {
    const data=history.candles[asset].filter(x=>x.intervalStart>=history.start&&x.intervalStart<history.end);
    assert.equal(new Set(data.map(x=>x.intervalStart)).size,data.length);
    prices[asset]=data;
  }
  const windows=[];
  for(let t=history.start;t+daySeconds<=trainingEnd;t+=DAY) {
    let net=0,travel=0;const changes={};
    for(const asset of ['ETH','BTC']) {
      const d=prices[asset].filter(x=>x.intervalStart>=t&&x.intervalStart<t+daySeconds);
      changes[asset]=d.at(-1).close/d[0].open-1;
      net+=Math.log(d.at(-1).close/d[0].open)/2;
      // Daily closes reduce microstructure noise; missing hourly candles are
      // not zero returns and are not synthesized to classify a regime.
      let prev=d[0].open;
      for(let a=t;a<t+daySeconds;a+=DAY) {
        const close=d.filter(x=>x.intervalStart>=a&&x.intervalStart<a+DAY).at(-1)?.close;
        assert.ok(close>0);travel+=Math.abs(Math.log(close/prev))/2;prev=close;
      }
    }
    windows.push({from:t,to:t+daySeconds,net,travel,changes,chop:travel-Math.abs(net)});
  }
  const bull=[...windows].sort((a,b)=>b.net-a.net)[0],bear=[...windows].sort((a,b)=>a.net-b.net)[0];
  const saw=[...windows].filter(x=>Math.abs(x.net)<=.03).sort((a,b)=>b.chop-a.chop)[0];
  assert.ok(saw,'no sideways choppy period found; do not invent one');
  return [{name:'bull',...bull},{name:'bear-pullback',...bear},{name:'saw',...saw}];
}
