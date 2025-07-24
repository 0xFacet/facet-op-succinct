import { config } from '@/lib/config'
import { getL1Chain, getL2Chain } from '@/lib/config'

export function ContractsFooter() {
  const l1Chain = getL1Chain()
  const l2Chain = getL2Chain()
  
  const l1Explorer = l1Chain.blockExplorers?.default.url || 'https://sepolia.etherscan.io'
  const l2Explorer = l2Chain.blockExplorers?.default.url || 'https://sepolia.explorer.facet.org'
  
  return (
    <footer className="bg-gray-100 border-t border-gray-200 mt-20">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
          {/* Contract Addresses */}
          <div>
            <h3 className="text-sm font-semibold text-gray-900 uppercase tracking-wider mb-4">
              Contract Addresses
            </h3>
            <ul className="space-y-3">
              <li>
                <div className="text-sm text-gray-600">Rollup Contract</div>
                <a 
                  href={`${l1Explorer}/address/${config.rollupAddress}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-xs sm:text-sm text-blue-600 hover:text-blue-700 font-mono break-all"
                >
                  {config.rollupAddress}
                </a>
              </li>
              <li>
                <div className="text-sm text-gray-600">L1 Bridge</div>
                <a 
                  href={`${l1Explorer}/address/${config.l1BridgeAddress}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-xs sm:text-sm text-blue-600 hover:text-blue-700 font-mono break-all"
                >
                  {config.l1BridgeAddress}
                </a>
              </li>
              <li>
                <div className="text-sm text-gray-600">L2 Bridge</div>
                <a 
                  href={`${l2Explorer}/address/${config.l2BridgeAddress}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-xs sm:text-sm text-blue-600 hover:text-blue-700 font-mono break-all"
                >
                  {config.l2BridgeAddress}
                </a>
              </li>
            </ul>
          </div>

          {/* Networks */}
          <div>
            <h3 className="text-sm font-semibold text-gray-900 uppercase tracking-wider mb-4">
              Networks
            </h3>
            <ul className="space-y-3">
              <li>
                <div className="text-sm text-gray-600">L1 Network</div>
                <div className="text-sm text-gray-900">{l1Chain.name}</div>
              </li>
              <li>
                <div className="text-sm text-gray-600">L2 Network</div>
                <div className="text-sm text-gray-900">{l2Chain.name}</div>
              </li>
            </ul>
          </div>

          {/* Resources */}
          <div>
            <h3 className="text-sm font-semibold text-gray-900 uppercase tracking-wider mb-4">
              Resources
            </h3>
            <ul className="space-y-3">
              <li>
                <a 
                  href="https://github.com/0xFacet/zk-fault-proofs"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-sm text-blue-600 hover:text-blue-700 flex items-center gap-1"
                >
                  <svg className="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
                  </svg>
                  Project README
                </a>
              </li>
              <li>
                <a 
                  href="https://docs.facet.org"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-sm text-blue-600 hover:text-blue-700"
                >
                  Facet Documentation
                </a>
              </li>
              <li>
                <a 
                  href="https://github.com/succinctlabs/sp1"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-sm text-blue-600 hover:text-blue-700"
                >
                  SP1 zkVM
                </a>
              </li>
            </ul>
          </div>
        </div>

        <div className="mt-8 pt-8 border-t border-gray-300">
          <p className="text-sm text-gray-500 text-center">
            Facet ZK Fault Proofs - Built with SP1 by Succinct
          </p>
        </div>
      </div>
    </footer>
  )
}