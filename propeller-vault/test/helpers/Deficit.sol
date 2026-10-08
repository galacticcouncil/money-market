// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {CollateralVault} from "../../src/CollateralVault.sol";
import {PropellerMainDebt} from "../../src/PropellerMainDebt.sol";
import {PropellerYieldAccounting} from "../../src/PropellerYieldAccounting.sol";
import {IPropellerFeeController} from "../../src/interfaces/IPropellerFeeController.sol";

/// @dev the deficit the keeper computes off-chain now that the contracts no longer guard it
library Deficit {
    function active(PropellerMainDebt m) internal view returns (bool) {
        CollateralVault v = CollateralVault(m.vault());
        uint256 debt = m.debtOf(0);
        if (debt == 0) return false;
        // no gross carry services interest at a 100% fee
        IPropellerFeeController fees = v.feeController();
        if (address(fees) != address(0) && fees.protocolFeeBps(address(v)) == 10_000
            && m.interestOf(0) > m.activeFunds()) return true;
        PropellerYieldAccounting rewards = v.yieldAccounting();
        uint256 backing = v.yieldSource().equityOf(address(v)) * 1e10 - rewards.sourceValue();
        return backing + m.activeFunds() < debt || backing < rewards.requiredSourceBacking();
    }

    function ready(PropellerMainDebt m) internal view returns (bool) {
        return !active(m) && !m.pendingSourceAccounting();
    }

    function underfunded(CollateralVault v) internal view returns (bool) {
        if (v.totalAssets() < v.totalQueuedCollateral()) return true;
        uint256 debt = v.hollarDebtToken().balanceOf(address(v));
        if (debt == 0) return false;
        uint256 backing8 = v.yieldSource().equityOf(address(v))
            + (v.yieldSource().pendingUnwindOf(address(v)) + v.hollar().balanceOf(address(v))) / 1e10;
        PropellerMainDebt m = PropellerMainDebt(address(v.mainDebt()));
        if (address(m) != address(0)) {
            if (active(m)) return true;
            backing8 += m.ownedCash() / 1e10;
            backing8 -= v.yieldAccounting().sourceValue() / 1e10;
            uint256 reserved = m.sourceFeeReserve() / 1e10;
            if (reserved > backing8) return true;
            backing8 -= reserved;
        }
        return v.yieldSource().negativeCarryBps() != 0 || backing8 < debt / 1e10;
    }
}
