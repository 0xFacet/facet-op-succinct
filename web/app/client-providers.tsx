'use client'

import dynamic from 'next/dynamic'

export const ClientProviders = dynamic(() => import('./providers').then(mod => mod.Providers), {
  ssr: false,
})