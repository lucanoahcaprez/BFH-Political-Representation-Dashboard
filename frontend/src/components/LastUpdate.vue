<script setup lang="ts">
import { ref, onMounted } from 'vue'
import axios from 'axios'
import { useI18n } from 'vue-i18n'
const { t } = useI18n()
const lastUpdate = ref<string | null>(null)

onMounted(async () => {
  try {
    const res = await axios.get('http://localhost:3000/api/last-update')
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
