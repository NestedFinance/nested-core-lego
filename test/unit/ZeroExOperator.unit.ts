import { LoadFixtureFunction } from "../types";
import { ActorFixture } from "../shared/helpers/actors";
import { createFixtureLoader, describeWithoutFork, expect, provider } from "../shared/helpers/provider";
import { BigNumber, Wallet } from "ethers";
import { ZeroExOperatorFixture } from "../shared/helpers/fixtures/zeroExOperatorFixture";

let loadFixture: LoadFixtureFunction;

/*
 * The operator's in-depth tests are in the factory tests.
 */
describeWithoutFork("ZeroExOperator", () => {
    let context: ZeroExOperatorFixture;
    const actors = new ActorFixture(provider.getWallets() as Wallet[], provider);

    before("loader", async () => {
        loadFixture = createFixtureLoader(provider.getWallets(), provider);
    });

    beforeEach("create fixture loader", async () => {
        context = await loadFixture(zeroExOperatorFixture);
    });

    it("deploys and has an address", async () => {
        expect(context.zeroExOperator.address).to.be.a.string;
        expect(context.dummyRouter.address).to.be.a.string;
    });

    it("has swapTarget (storage)", async () => {
        expect(context.zeroExOperator.operatorStorage()).to.be.a.string;
    });

    describe("performSwap()", () => {
        it("Swap tokens", async () => {
            let initDaiBalance = await context.mockDAI.balanceOf(context.testableOperatorCaller.address);
            let initUniBalance = await context.mockUNI.balanceOf(context.testableOperatorCaller.address);
            const amount = 1000;
            // Calldata swap 1000 DAI against 1000 UNI
            let calldata = context.dummyRouterInterface.encodeFunctionData("dummyswapToken", [
                context.mockDAI.address,
                context.mockUNI.address,
                amount,
            ]);

            // Run swap
            await context.testableOperatorCaller
                .connect(actors.user1())
                .performSwap(
                    context.zeroExOperator.address,
                    context.mockDAI.address,
                    context.mockUNI.address,
                    calldata,
                );

            expect(await context.mockDAI.balanceOf(context.testableOperatorCaller.address)).to.be.equal(
                initDaiBalance.sub(BigNumber.from(amount)),
            );
            expect(await context.mockUNI.balanceOf(context.testableOperatorCaller.address)).to.be.equal(
                initUniBalance.add(BigNumber.from(amount)),
            );
        });

        it("Can't swap 0 tokens", async () => {
            const amount = 0;

            // Calldata swap 1000 DAI against 1000 UNI
            let calldata = context.dummyRouterInterface.encodeFunctionData("dummyswapToken", [
                context.mockDAI.address,
                context.mockUNI.address,
                amount,
            ]);

            // Run swap
            await expect(
                context.testableOperatorCaller
                    .connect(actors.user1())
                    .performSwap(
                        context.zeroExOperator.address,
                        context.mockDAI.address,
                        context.mockUNI.address,
                        calldata,
                    ),
            ).to.be.revertedWith("TestableOperatorCaller::performSwap: Error");
        });
    });
});
