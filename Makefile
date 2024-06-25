ts-bindings:
	npx typechain --target ethers-v5 ./out/**[!o]/*.json --out-dir ./typechain-types