import { defineConfig, loadEnv } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'

// 端口与地址的环境基线见 .env.example；默认值与历史行为一致。
// strictPort: 端口被占用时立即报错退出，而不是静默切换端口。
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, __dirname, 'VITE_')
  const host = env.VITE_DEV_HOST || '0.0.0.0'

  return {
    plugins: [vue()],
    resolve: {
      alias: { '@': resolve(__dirname, 'src') }
    },
    server: {
      host,
      port: Number(env.VITE_DEV_PORT) || 5173,
      strictPort: true
    },
    preview: {
      host,
      port: Number(env.VITE_PREVIEW_PORT) || 4173,
      strictPort: true
    },
    css: {
      preprocessorOptions: {
        scss: {
          additionalData: `@use "@/styles/variables" as *;`
        }
      }
    }
  }
})
