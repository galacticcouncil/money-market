from pathlib import Path
import json, re, subprocess, sys

# Run each batch once (0..3); the union covers every .t.sol file.
root=Path(__file__).resolve().parents[3]
output=Path(sys.argv[2]) if len(sys.argv)>2 else Path('/tmp/propeller-ownership-verification')
output.mkdir(parents=True,exist_ok=True)
all_files={str(p.relative_to(root)) for p in (root/'test').rglob('*.t.sol')}
groups=[
 ['Harvest','HarvestMainDebt','ProtocolFees','YieldEntryFairness','YieldCheckpointGas','DcaDispatch','PropellerDiscount','PropellerDiscountFork','ProtocolFeesFork','SyntheticToken'],
 ['MultiVaultFlow','RecoveryE2E','MainDebtCampaign','Market90Days','YieldFundedExecution','SourceUpgradeCompatibility'],
 ['PluggableYieldSource','InterestPolicyEvidence','MainDebt','PrincipalRounding','AccountingSafety','WithdrawalCooldown','SubLoopUnwind','NegativeCarryView','SynthLtvZero','SubLoopDeploy'],
]
groups=[['test/'+name+'.t.sol' for name in group] for group in groups]
groups.append(sorted(all_files-set(sum(groups,[]))))
assert len(sum(groups,[]))==len(all_files)==len(set(sum(groups,[])))
which=int(sys.argv[1])
selected=groups[which]
keep=set(selected)
def add_dependencies(file):
 for imported in re.findall(r'from\s+"([^"]+\.t\.sol)"',(root/file).read_text()):
  dep=str((root/file).parent.joinpath(imported).resolve().relative_to(root))
  if dep not in keep:
   keep.add(dep)
   add_dependencies(dep)
for file in selected: add_dependencies(file)
# Forge's skip filters are substrings: skipping MainDebt.t.sol would also
# suppress HarvestMainDebt.t.sol. Compile such collisions but exclude their
# tests with the exact contract-name selection below.
while True:
 collisions={file for file in all_files-keep if any(Path(file).name in Path(k).name for k in keep)}
 if not collisions: break
 for file in collisions:
  keep.add(file)
  add_dependencies(file)
names=[]
for file in selected:
 names+=re.findall(r'contract\s+(\w+Test)\s+is\s+', (root/file).read_text())
assert names
args=['forge','test','--offline','--evm-version','london','-j','2','-vv','--skip','script','--match-contract','^('+'|'.join(names)+')$',
      '--out',str(output/f'batch-{which}-out'),'--cache-path',str(output/f'batch-{which}-cache')]
for file in sorted(all_files-keep): args+=['--skip',Path(file).name]
(output/f'batch-{which}.json').write_text(json.dumps({'cwd':str(root),'files':selected,'contracts':names,'args':args},indent=2)+'\n')
with open(output/f'batch-{which}.log','w') as log:
 result=subprocess.run(args,cwd=root,stdout=log,stderr=subprocess.STDOUT)
raise SystemExit(result.returncode)
