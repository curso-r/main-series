library(fable)
library(feasts)
library(timetk)
library(modeltime)
library(tidymodels)
library(tsibble)
library(tidyverse)


anac_regiao <- readr::read_rds("https://github.com/curso-r/main-series/blob/main/dados/anac-br.rds?raw=true") %>%
  filter(
    AEROPORTO_DE_DESTINO_REGIAO != "NÃO IDENTIFICADO") |>
  rename(
    REGIAO = AEROPORTO_DE_DESTINO_REGIAO,
    UF = AEROPORTO_DE_DESTINO_UF
  ) |>
  filter(!(REGIAO == "NORDESTE" & UF == "MG")) |>
  mutate(DATA_ym = tsibble::yearmonth(paste(ANO, MES, sep = "-"))) %>%
  mutate(
    TEMPO_DESDE_INICIO = difftime(
      DATA,
      lubridate::ymd("1999-12-01"),
      units = "days"
    )/30,
    LAG_1 = lag(PASSAGEIROS_PAGOS, 1, default = 0),
    CARGA_LAG = lag(CARGA_PAGA_KG),
    dif_CARGA_LAG = CARGA_LAG - lag(CARGA_LAG, 2)
  ) |>
  filter(DATA <= as.Date("2018-12-31"))

anac_regiao_ts <- anac_regiao |>
  as_tsibble(index = DATA_ym,
             key = c(REGIAO, UF))

anac_regiao %>%
  filter(REGIAO == "SUDESTE") |>
  group_by(REGIAO, UF) %>%
  plot_time_series(
    DATA, PASSAGEIROS_PAGOS, .facet_ncol = 2
  )

meses_previsao <- 24

anac_regiao_nested <- anac_regiao |>
  mutate(
    id_serie = paste0(REGIAO, UF)
  ) |>
  # 1. Extending: We'll predict 52 weeks into the future.
  extend_timeseries(
    .id_var        = id_serie,
    .date_var      = DATA,
    .length_future = meses_previsao
  ) %>%

  # 2. Nesting: We'll group by id, and create a future dataset
  #    that forecasts 52 weeks of extended data and
  #    an actual dataset that contains 104 weeks (2-years of data)
  nest_timeseries(
    .id_var        = id_serie,
    .length_future = meses_previsao,
    .length_actual = 228-meses_previsao
  ) %>%

  # 3. Splitting: We'll take the actual data and create splits
  #    for accuracy and confidence interval estimation of 52 weeks (test)
  #    and the rest is training data
  split_nested_timeseries(
    .length_test = meses_previsao
  )

rec_arima <- recipe(PASSAGEIROS_PAGOS ~ DATA,
                    extract_nested_train_split(anac_regiao_nested))


wflw_arima <- workflow() %>%
  add_model(
    arima_reg() |>
      set_engine("auto_arima")
  ) %>%
  add_recipe(rec_arima)

wflw_ets <- workflow() %>%
  add_model(
    seasonal_reg() |>
      set_engine("tbats")
  ) %>%
  add_recipe(rec_arima)

wflw_ets <- workflow() %>%
  add_model(
    modeltime::seasonal_reg() |>
      set_engine("tbats")
  ) %>%
  add_recipe(rec_arima)

modelos_ajustados <- modeltime_nested_fit(
  nested_data = anac_regiao_nested,
  wflw_ets,
  wflw_arima
)

modelos_ajustados |>
  modeltime::extract_nested_test_accuracy() |>
  View()

melhores_modelos <- modelos_ajustados |>
  modeltime::modeltime_nested_select_best() |>
  modeltime::extract_nested_best_model_report()

modelos_ajustados |>
  modeltime_nested_select_best() |>
  extract_nested_test_forecast() |>
  mutate(
    previsto = if_else(.model_desc == "ACTUAL", "observado", "previsto")
  ) |>
  group_by(.index,
           #.model_id,
           previsto) |>
  summarise(
    .value = sum(.value)
  ) |>
  pivot_wider(names_from = previsto,
              values_from = .value) |>
  #group_by(.model_id) |>
  ungroup() |>
  summarise(
    MASE = mase_vec(observado, previsto),
    MAPE = mape_vec(observado, previsto),
    RSQ = rsq_vec(observado, previsto)
  )

modelos_ajustados |>
  extract_nested_test_forecast() |>
  filter(id_serie == "CENTRO-OESTEGO") |>
  plot_modeltime_forecast()
