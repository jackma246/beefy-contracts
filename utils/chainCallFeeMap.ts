import { BeefyChain } from "./beefyChain"

const defaultFee = 111;
const reducedFee = 11;

export const chainCallFeeMap: Record<BeefyChain, number> = {
  localhost: defaultFee,
  telos: defaultFee,
};
