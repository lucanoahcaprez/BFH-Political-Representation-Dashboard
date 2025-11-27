<script setup lang="ts">
import { ref, onMounted } from 'vue'
import axios from 'axios'
import { useI18n } from 'vue-i18n'
const { t } = useI18n()
const lastUpdate = ref<string | null>(null)
const API_BASE_URL =
  (import.meta.env.VITE_API_BASE_URL as string | undefined)?.replace(/\/$/, '') ?? ''

onMounted(async () => {
  try {
    const res = await axios.get(`${API_BASE_URL}/api/last-update`)
    lastUpdate.value = res.data.lastModified
  } catch (e) {
    console.error('Could not fetch last update:', e)
  }
})
</script>

<template>
  <div class="text-sm text-gray-500 mt-2 text-center">
    {{ t('footer.lastUpdate') }}:
    <span v-if="lastUpdate">{{ lastUpdate }}</span>
    <span v-else>{{ t('footer.loading') }}</span>
  </div>
</template>
