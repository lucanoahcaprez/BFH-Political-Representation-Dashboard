<script setup lang="ts">
import { ref, onMounted } from 'vue'
import axios from 'axios'
import { useI18n } from 'vue-i18n'
const { t } = useI18n()

type SwissvotesFetchMeta = {
  status: string | null
  timestamp: string | null
  error: string | null
}

const lastUpdate = ref<string | null>(null)
const swissvotesFetch = ref<SwissvotesFetchMeta | null>(null)
const locale =
  typeof navigator !== 'undefined' && navigator.language ? navigator.language : 'de-CH'

function formatTimestamp(value: string | null): string | null {
  if (!value) return null

  // Normalize space-separated timestamps to ISO-like strings so Date can parse reliably.
  const normalized = value.includes('T') ? value : value.replace(' ', 'T')
  const date = new Date(normalized)
  if (Number.isNaN(date.getTime())) return value

  return date.toLocaleString(locale, {
    timeZone: 'Europe/Zurich',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  })
}

const API_BASE_URL =
  (import.meta.env.VITE_API_BASE_URL as string | undefined)?.replace(/\/$/, '') ?? ''

onMounted(async () => {
  try {
    const res = await axios.get(`${API_BASE_URL}/api/last-update`)
    lastUpdate.value = formatTimestamp(res.data.lastModified ?? null)
    swissvotesFetch.value = {
      status: res.data.swissvotesFetch?.status ?? null,
      timestamp: formatTimestamp(res.data.swissvotesFetch?.timestamp ?? null),
      error: res.data.swissvotesFetch?.error ?? null
    }
  } catch (e) {
    console.error('Could not fetch last update:', e)
  }
})
</script>

<template>
  <div class="text-sm text-gray-500 mt-2 text-center flex flex-col gap-1">
    <div>
      {{ t('footer.lastUpdate') }}:
      <span v-if="lastUpdate">{{ lastUpdate }}</span>
      <span v-else>{{ t('footer.loading') }}</span>
    </div>
    <div>
      <template v-if="swissvotesFetch">
        <template v-if="swissvotesFetch.status === 'success'">
          {{ t('footer.lastSwissvotesFetch') }}:
          <span v-if="swissvotesFetch.timestamp">{{ swissvotesFetch.timestamp }}</span>
          <span v-else>{{ t('footer.loading') }}</span>
        </template>
        <template v-else-if="swissvotesFetch.status === 'failed'">
          {{ t('footer.fetchFailed') }}:
          <span v-if="swissvotesFetch.timestamp">{{ swissvotesFetch.timestamp }}</span>
          <span v-else>{{ t('footer.loading') }}</span>
          <span v-if="swissvotesFetch.error"> ({{ swissvotesFetch.error }})</span>
        </template>
        <template v-else>
          {{ t('footer.lastSwissvotesFetch') }}: {{ t('footer.loading') }}
        </template>
      </template>
      <span v-else>{{ t('footer.loading') }}</span>
    </div>
  </div>
</template>
