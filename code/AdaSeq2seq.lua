-- Based on https://github.com/Element-Research/rnn/blob/master/examples/encoder-decoder-coupling.lua
local AdaSeq2Seq = torch.class("neuralconvo.AdaSeq2Seq")

function AdaSeq2Seq:__init(vocabSize, hiddenSize)
  self.vocabSize = assert(vocabSize, "vocabSize required at arg #1")
  self.hiddenSize = assert(hiddenSize, "hiddenSize required at arg #2")

  self:buildModel()
end

function AdaSeq2Seq:buildModel()
  local para = nn.ParallelTable()
  local lookupModule = nn.Sequential()
  local linearModule = nn.Sequential()
  lookupModule:add(nn.LookupTable(self.vocabSize, self.hiddenSize))
  linearModule:add(nn.Linear(400, self.hiddenSize))
  para:add(linearModule):add(lookupModule)
  self.encoder = nn.Sequential()
  self.encoder:add(para)
  self.encoder:add(nn.CAddTable())
  self.encoder:add(nn.SplitTable(1, 2))
  -- self.encoder:add(nn.LookupTable(self.vocabSize, self.hiddenSize))
  -- self.encoder:add(nn.SplitTable(1, 2))
  self.encoderLSTM = nn.LSTM(self.hiddenSize, self.hiddenSize)
  self.encoder:add(nn.Sequencer(self.encoderLSTM))
  self.encoder:add(nn.SelectTable(-1))

  self.decoder = nn.Sequential()
  self.decoder:add(nn.LookupTable(self.vocabSize, self.hiddenSize))
  self.decoder:add(nn.SplitTable(1, 2))
  self.decoderLSTM = nn.LSTM(self.hiddenSize, self.hiddenSize)
  self.decoder:add(nn.Sequencer(self.decoderLSTM))
  self.decoder:add(nn.Sequencer(nn.Linear(self.hiddenSize, self.vocabSize)))
  self.decoder:add(nn.Sequencer(nn.LogSoftMax()))

  self.encoder:zeroGradParameters()
  self.decoder:zeroGradParameters()

  self.zeroTensor = torch.Tensor(2):zero()
end

function AdaSeq2Seq:cuda()
  self.encoder:cuda()
  self.decoder:cuda()

  if self.criterion then
    self.criterion:cuda()
  end

  self.zeroTensor = self.zeroTensor:cuda()
end

--[[ Forward coupling: Copy encoder cell and output to decoder LSTM ]]--
function AdaSeq2Seq:forwardConnect(inputSeqLen)
  self.decoderLSTM.userPrevOutput =
    nn.rnn.recursiveCopy(self.decoderLSTM.userPrevOutput, self.encoderLSTM.outputs[inputSeqLen])
  self.decoderLSTM.userPrevCell =
    nn.rnn.recursiveCopy(self.decoderLSTM.userPrevCell, self.encoderLSTM.cells[inputSeqLen])
end

--[[ Backward coupling: Copy decoder gradients to encoder LSTM ]]--
function AdaSeq2Seq:backwardConnect()
  self.encoderLSTM.userNextGradCell =
    nn.rnn.recursiveCopy(self.encoderLSTM.userNextGradCell, self.decoderLSTM.userGradPrevCell)
  self.encoderLSTM.gradPrevOutput =
    nn.rnn.recursiveCopy(self.encoderLSTM.gradPrevOutput, self.decoderLSTM.userGradPrevOutput)
end

function AdaSeq2Seq:train(input, target)
  local encoderInput = input
  local decoderInput = target:sub(1, -2)
  local decoderTarget = target:sub(2, -1)

  -- Forward pass
  self.encoder:forward({input, decoderInput})
  self:forwardConnect(input:size(1))
  local decoderOutput = self.decoder:forward(decoderInput)
  local Edecoder = self.criterion:forward(decoderOutput, decoderTarget)

  if Edecoder ~= Edecoder then -- Exist early on bad error
    return Edecoder
  end

  -- Backward pass
  local gEdec = self.criterion:backward(decoderOutput, decoderTarget)
  self.decoder:backward(decoderInput, gEdec)
  self:backwardConnect()
  self.encoder:backward({input, decoderInput}, self.zeroTensor)

  self.encoder:updateGradParameters(self.momentum)
  self.decoder:updateGradParameters(self.momentum)
  self.decoder:updateParameters(self.learningRate)
  self.encoder:updateParameters(self.learningRate)
  self.encoder:zeroGradParameters()
  self.decoder:zeroGradParameters()

  self.decoder:forget()
  self.encoder:forget()

  return Edecoder
end

local MAX_OUTPUT_SIZE = 20

function AdaSeq2Seq:eval(input)
  assert(self.goToken, "No goToken specified")
  assert(self.eosToken, "No eosToken specified")

  self.encoder:forward(input)
  self:forwardConnect(input:size(1))

  local predictions = {}
  local probabilities = {}

  -- Forward <go> and all of it's output recursively back to the decoder
  local output = self.goToken

  for i = 1, MAX_OUTPUT_SIZE do
    local prediction = self.decoder:forward(torch.Tensor{output})[1]
    -- prediction contains the probabilities for each word IDs.
    -- The index of the probability is the word ID.
    local prob, wordIds = prediction:sort(1, true)

    -- First one is the most likely.
    output = wordIds[1]

    -- Terminate on EOS token
    if output == self.eosToken then
      break
    end

    table.insert(predictions, wordIds)
    table.insert(probabilities, prob)
  end 

  self.decoder:forget()
  self.encoder:forget()

  return predictions, probabilities
end