# pbi_theme.rb — Power BI report theme -> Sigma workbook themeOverrides.
#
# The single biggest style-fidelity gap in PBI->Sigma migration was that we
# reproduced data + layout but NOT the visual theme: no categorical palette, no
# card chrome, no borders. Everything a Sigma workbook needs to look like its
# PBI source is derivable from the report's base theme name + the built-in PBI
# palettes below. See refs/style-fidelity.md.
#
# Order matters: Sigma assigns categoricalScheme[i] to the i-th category/series,
# exactly as PBI colors by legend order — so the palette sequence must match the
# PBI theme's data-color sequence for donut/pie slices and multi-series charts
# to line up.
module PbiTheme
  # Built-in PBI report-theme data-color sequences. 'CY24SU10' is the 2024+
  # default ("Power BI"); the classic sequence covers pre-2023 reports.
  PALETTES = {
    'CY24SU10' => %w[#118DFF #12239E #E66C37 #6B007B #E044A7 #744EC2 #D9B300 #D64550],
    'CY23SU08' => %w[#118DFF #12239E #E66C37 #6B007B #E044A7 #744EC2 #D9B300 #D64550],
    'classic'  => %w[#01B8AA #374649 #FD625E #F2C80F #5F6B6D #8AD4EB #FE9666 #A66999]
  }.freeze
  # PBI's current default when the report names no explicit theme.
  FALLBACK = PALETTES['CY24SU10']

  def self.palette(theme_name)
    PALETTES[theme_name.to_s] || FALLBACK
  end

  # scheme[0] — PBI colors single-series charts AND card values with it.
  def self.accent(theme_name)
    palette(theme_name).first
  end

  # The Sigma themeOverrides that reproduce a PBI report's look: card chrome,
  # subtle 1px borders, rounded corners, and the source palette (which drives
  # donut/pie + multi-series colors). Stacked on the built-in `Light` theme.
  def self.overrides(theme_name)
    pal = palette(theme_name)
    {
      'hasCards'          => 'shown',
      'borderRadius'      => 'round',
      'elementBorder'     => { 'color' => '#E2E8F0', 'width' => 1 },
      'categoricalScheme' => pal,
      'colors'            => { 'highlight' => pal.first }
    }
  end
end
