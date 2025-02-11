import { ethers } from "hardhat";
import { expect, use } from "chai";
import { solidity } from "ethereum-waffle";

// Contract Types
import { SignatureMint1155 } from "typechain/SignatureMint1155";

// Types
import { BigNumber, BytesLike } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

// Test utils
import { getContracts, Contracts } from "../../../utils/tests/getContracts";

use(solidity);

describe("Initial state of SignatureMint1155 on deployment", function () {
  // Signers
  let protocolProvider: SignerWithAddress;
  let protocolAdmin: SignerWithAddress;
  let defaultSaleRecipient: SignerWithAddress;

  // Contracts
  let sigMint1155: SignatureMint1155;

  // Deployment params
  const contractURI: string = "ipfs://contractURI/";
  let trustedForwarderAddr: string;
  let protocolControlAddr: string;
  let nativeTokenWrapperAddr: string;
  let royaltyRecipient: string;
  const royaltyBps: BigNumber = BigNumber.from(0);
  const feeBps: BigNumber = BigNumber.from(0);

  before(async () => {
    [protocolProvider, protocolAdmin, defaultSaleRecipient] = await ethers.getSigners();
  });

  beforeEach(async () => {
    const contracts: Contracts = await getContracts(protocolProvider, protocolAdmin);

    trustedForwarderAddr = contracts.forwarder.address;
    protocolControlAddr = contracts.protocolControl.address;
    nativeTokenWrapperAddr = contracts.weth.address;
    royaltyRecipient = protocolAdmin.address;

    sigMint1155 = (await ethers
      .getContractFactory("SignatureMint1155")
      .then(f =>
        f
          .connect(protocolAdmin)
          .deploy(
            contractURI,
            protocolControlAddr,
            trustedForwarderAddr,
            nativeTokenWrapperAddr,
            defaultSaleRecipient.address,
            royaltyRecipient,
            royaltyBps,
            feeBps,
          ),
      )) as SignatureMint1155;
  });

  it("Should grant all relevant roles to contract deployer", async () => {
    const DEFAULT_ADMIN_ROLE: BytesLike = await sigMint1155.DEFAULT_ADMIN_ROLE();
    const MINTER_ROLE: BytesLike = await sigMint1155.MINTER_ROLE();
    const TRANSFER_ROLE: BytesLike = await sigMint1155.TRANSFER_ROLE();

    expect(await sigMint1155.hasRole(DEFAULT_ADMIN_ROLE, protocolAdmin.address)).to.be.true;
    expect(await sigMint1155.hasRole(MINTER_ROLE, protocolAdmin.address)).to.be.true;
    expect(await sigMint1155.hasRole(TRANSFER_ROLE, protocolAdmin.address)).to.be.true;
  });

  it("Should initialize relevant state variables in the constructor", async () => {
    expect(await sigMint1155.nativeTokenWrapper()).to.equal(nativeTokenWrapperAddr);
    expect(await sigMint1155.defaultSaleRecipient()).to.equal(defaultSaleRecipient.address);
    expect(await sigMint1155.contractURI()).to.equal(contractURI);
  });
});
