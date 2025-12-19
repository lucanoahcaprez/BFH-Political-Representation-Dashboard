<template>
  <footer class="footer">
    <div class="footer-wrapper">
      <img
          src="/logo-bfh.svg"
          alt="Berner Fachhochschule"
          class="bfh-logo"
      />

      <div class="footer-text">
        <p><LastUpdate /></p>
        <p>
          {{ t('footer.dataSource') }}
          <a href="https://swissvotes.ch" target="_blank" rel="noopener">Swissvotes</a>
        </p>

        <p>{{ t('footer.projectInfo') }}</p>

        <p>
          {{ t('footer.authorsv1') }}
          <a href="https://www.linkedin.com/in/damian-lienhart-870208299/" target="_blank" rel="noopener">Damian Lienhart</a>,
          <a href="https://www.linkedin.com/in/sujal-singh-basnet-99106a300/" target="_blank" rel="noopener">Sujal Singh Basnet</a>
          <br />
          {{ t('footer.authorsv2') }}
          <a href="https://www.linkedin.com/in/elia-bucher-1567b71a0/" target="_blank" rel="noopener">Elia Bucher</a>,
          <a href="https://lucanoahcaprez.ch/me" target="_blank" rel="noopener">Luca Caprez</a>,
          <a href="https://www.linkedin.com/in/pascal-marc-feller-600b48231/" target="_blank" rel="noopener">Pascal Feller</a>
          <br />
          {{ t('footer.supervisor') }}
          <a href="https://www.simon-kramer.ch/" target="_blank" rel="noopener">Dr. Simon Kramer</a>
        </p>




        <p>
          {{ t('footer.license') }}
          <a href="https://opensource.org/license/mit/" target="_blank" rel="noopener">MIT</a>.
        </p>

        <div class="footer-validators">
          <p class="footer-section-title">{{ t('footer.validatorsTitle') }}</p>
          <ul class="validator-list">
            <li>
              <span class="validator-check" aria-hidden="true"></span>
              <a :href="validatorLinks.html" target="_blank" rel="noopener">HTML Validator</a>
            </li>
            <li>
              <span class="validator-check" aria-hidden="true"></span>
              <a :href="validatorLinks.css" target="_blank" rel="noopener">CSS Validator</a>
            </li>
            <li>
              <span class="validator-check" aria-hidden="true"></span>
              <a :href="validatorLinks.i18n" target="_blank" rel="noopener">I18N Checker</a>
            </li>
            <li>
              <span class="validator-check" aria-hidden="true"></span>
              <a :href="validatorLinks.ssl" target="_blank" rel="noopener">SSL Labs Test</a>
            </li>
            <li>
              <span class="validator-check" aria-hidden="true"></span>
              <a :href="validatorLinks.safeBrowsing" target="_blank" rel="noopener">Safe Browsing</a>
            </li>
            <li>
              <span class="validator-check" aria-hidden="true"></span>
              <a :href="validatorLinks.hardenize" target="_blank" rel="noopener">Hardenize Report</a>
            </li>
          </ul>
        </div>

        <p class="footer-year">© 2025 Berner Fachhochschule</p>
      </div>
    </div>
  </footer>
</template>



<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import LastUpdate from '@/components/LastUpdate.vue'

const { t } = useI18n()

const encodedUrl = computed(() => {
  if (typeof window === 'undefined') return ''
  return encodeURIComponent(window.location.href)
})

const currentHost = computed(() => {
  if (typeof window === 'undefined') return ''
  try {
    return new URL(window.location.href).hostname
  } catch {
    return ''
  }
})

const validatorLinks = computed(() => ({
  html: `https://validator.w3.org/nu/?doc=${encodedUrl.value}&ucn_task=conformance`,
  css: `https://jigsaw.w3.org/css-validator/validator?uri=${encodedUrl.value}`,
  i18n: `https://validator.w3.org/i18n-checker/check?uri=${encodedUrl.value}`,
  ssl: `https://www.ssllabs.com/ssltest/analyze.html?d=${currentHost.value}`,
  safeBrowsing: `https://transparencyreport.google.com/safe-browsing/search?url=${encodedUrl.value}`,
  hardenize: currentHost.value
    ? `https://www.hardenize.com/report/${currentHost.value}`
    : 'https://www.hardenize.com/'
}))
</script>

<style scoped>
.footer {
  background-color: #f0f0f0;
  padding: 2rem 1rem;
  font-size: 0.85rem;
  border-top: 1px solid #ddd;
  font-family: 'Inter', sans-serif;
}

.footer-wrapper {
  max-width: 1200px;
  margin: 0 auto;
  display: flex;
  flex-direction: column;
  align-items: center;
  text-align: center;
  gap: 1rem;
}

.footer-text {
  color: #444;
  max-width: 700px;
}

.bfh-logo {
  height: 80px;
}

.footer-content a,
.footer-text a {
  color: #2563eb;
  text-decoration: none;
}

.footer-content a:hover,
.footer-text a:hover {
  text-decoration: underline;
}

.footer-year {
  font-weight: 500;
  margin-top: 0.5rem;
  color: #666;
}

.footer-section-title {
  margin: 0.5rem 0 0.25rem;
  font-weight: 600;
}

.validator-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem 1rem;
}

.validator-list li {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.validator-check {
  width: 18px;
  height: 18px;
  border-radius: 999px;
  background: linear-gradient(145deg, #36d399, #22c55e);
  box-shadow: 0 2px 6px rgba(16, 185, 129, 0.35);
  position: relative;
  flex: 0 0 auto;
}

.validator-check::after {
  content: '';
  position: absolute;
  width: 6px;
  height: 10px;
  border: solid #fff;
  border-width: 0 2px 2px 0;
  top: 3px;
  left: 6px;
  transform: rotate(45deg);
}


@media (min-width: 768px) {
  .footer-wrapper {
    flex-direction: row;
    align-items: flex-start;
    text-align: left;
    gap: 2rem;
  }

  .bfh-logo {
    margin-top: 0.2rem;
    height: 120px;
  }

  .footer-text {
    flex: 1;
  }
}

</style>
