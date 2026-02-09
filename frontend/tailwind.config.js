/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,jsx}"],
  theme: {
    extend: {
      colors: {
        gold: {
          50: "#fdf8e8",
          100: "#f5ebc4",
          200: "#eddd9b",
          300: "#e8c468",
          400: "#d4a843",
          500: "#c49a38",
          600: "#a37e2e",
          700: "#7d6022",
          800: "#5c4619",
          900: "#3d2e10",
        },
        rank: {
          G: "#6b7280",
          F: "#10b981",
          E: "#3b82f6",
          D: "#06b6d4",
          C: "#8b5cf6",
          B: "#ec4899",
          A: "#f59e0b",
          S: "#eab308",
          SS: "#f97316",
          SSS: "#ef4444",
        },
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "sans-serif"],
        display: ["Inter", "system-ui", "sans-serif"],
      },
      animation: {
        "fade-in": "fadeIn 0.3s ease-out",
        "slide-up": "slideUp 0.3s ease-out",
        "pulse-gold": "pulseGold 2s ease-in-out infinite",
      },
      keyframes: {
        fadeIn: {
          "0%": { opacity: "0" },
          "100%": { opacity: "1" },
        },
        slideUp: {
          "0%": { opacity: "0", transform: "translateY(10px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        pulseGold: {
          "0%, 100%": { boxShadow: "0 0 0 0 rgba(212, 168, 67, 0.2)" },
          "50%": { boxShadow: "0 0 20px 4px rgba(212, 168, 67, 0.15)" },
        },
      },
    },
  },
  plugins: [],
};
