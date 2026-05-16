/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './app/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        ink: {
          0:   '#0f0f0f',
          50:  '#171717',
          100: '#1f1f1f',
          200: '#2a2a2a',
          300: '#404040',
          400: '#525252',
          500: '#737373',
          600: '#a3a3a3',
          700: '#d4d4d4',
          800: '#e5e5e5',
          900: '#fafafa',
        },
        amber: {
          400: '#fbbf24',
          500: '#f59e0b',
          600: '#d97706',
        },
        good: '#16a34a',
        warn: '#dc2626',
        info: '#3b82f6',
      },
      fontFamily: {
        mono: ['var(--font-geist-mono)', 'ui-monospace', 'SF Mono', 'Menlo', 'monospace'],
        sans: ['var(--font-geist-sans)', 'ui-sans-serif', 'system-ui', '-apple-system', 'sans-serif'],
      },
      fontSize: {
        'kpi-xl': ['2.5rem', { lineHeight: '1', letterSpacing: '-0.025em' }],
        'kpi':   ['1.75rem', { lineHeight: '1.1', letterSpacing: '-0.02em' }],
      },
      boxShadow: {
        panel: '0 0 0 1px rgba(255,255,255,0.06)',
        'panel-hover': '0 0 0 1px rgba(245,158,11,0.5), 0 8px 20px -8px rgba(245,158,11,0.2)',
      },
    },
  },
  plugins: [],
};
