'use client'

import { ConnectButton } from '@rainbow-me/rainbowkit'

export function WalletButton() {
  return (
    <ConnectButton 
      showBalance={true}
      accountStatus={{
        smallScreen: 'avatar',
        largeScreen: 'full',
      }}
    />
  )
}